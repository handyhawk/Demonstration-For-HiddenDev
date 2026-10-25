--// Basic Services

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "NetRemotes"

local DEFAULT_RATE_LIMIT = { Max = 30, Window = 1 }
local GLOBAL_RATE_LIMIT = { Max = 300, Window = 1 } -- all messages from one player combined
local DEFAULT_MAX_STRING_LENGTH = 1000
local MAX_QUEUED_PER_NAME = 64
local WARN_COOLDOWN = 5

local Net = {}

--// Helpers

local lastWarned = {}

local function debugWarn(key, message)
	local now = os.clock()
	if lastWarned[key] and now - lastWarned[key] < WARN_COOLDOWN then
		return
	end
	lastWarned[key] = now
	warn("[Net] " .. message)
end

local function safeCall(name, callback, ...)
	local ok, err = xpcall(callback, debug.traceback, ...)
	if not ok then
		warn(string.format("[Net] Handler for %q errored:\n%s", name, tostring(err)))
	end
end

local function checkName(name, level)
	if type(name) ~= "string" or name == "" then
		error("[Net] Message name must be a non-empty string", (level or 2) + 1)
	end
end

local function wrongSide(functionName, side)
	return function()
		error(string.format("[Net] Net.%s can only be used on the %s", functionName, side), 2)
	end
end


--// Creating Remotes and RemoteFolder

local remoteEvent, unreliableRemoteEvent, remoteFunction

if IS_SERVER then
	-- Clean up old folder
	local oldFolder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if oldFolder then
		oldFolder:Destroy()
	end
	
	-- Setting up new folder with 3 different remotes
	
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	
	
	remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = "RemoteEvent"
	remoteEvent.Parent = folder
	
	unreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
	unreliableRemoteEvent.Name = "UnreliableRemoteEvent"
	unreliableRemoteEvent.Parent = folder
	
	remoteFunction = Instance.new("RemoteFunction")
	remoteFunction.Name = "RemoteFunction"
	remoteFunction.Parent = folder
	
	folder.Parent = ReplicatedStorage
else
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	remoteEvent = folder:WaitForChild("RemoteEvent")
	unreliableRemoteEvent = folder:WaitForChild("UnreliableRemoteEvent")
	remoteFunction = folder:WaitForChild("RemoteFunction")
end

--// Server

if IS_SERVER then
	-- Validation
	
	local function isFinite(n)
		return n == n and n ~= math.huge and n ~= -math.huge
	end
	
	local function checkValue(expected, value, maxStringLength)
		local optional = string.sub(expected, -1) == "?"
		if optional then
			expected = string.sub(expected, 1, -2)
		end
		
		if value == nil then
			if optional then
				return true
			end
			return false, "got nil"
		end
		
		if expected == "any" then
			return true
		end
		
		local actual = typeof(value)
		if actual ~= expected then
			return false, "got" .. actual
		end
		
		if actual == "number" then
			if not isFinite(value) then
				return false, "numer is NaN or infinity"
			end
		elseif actual == "string" then
			if #value > maxStringLength then
				return false, string.format("string is %d characters (max %d)", #value, maxStringLength)
			end
		elseif actual == "Vector3" or actual == "Vector2" or actual == "CFrame" then
			local v = actual == "CFrame" and value.Position or value
			if not (isFinite(v.X) and isFinite(v.Y) and (actual == "Vector2" or isFinite(v.Z))) then
				return false, actual .. " contains NaN or infinite value"
			end
		end
		return true
	end
	
	local function validateArgs(types, maxStringLength, ...)
		local count = select("#", ...)
		if count > #types then
			return false, string.format("expected at most %d arguments(s), got %d", #types, count)
		end
		
		for index, expected in ipairs(types) do
			local value = (select(index, ...))
			local ok, why = checkValue(expected, value, maxStringLength)
			if not ok then
				return false, string.format("arguments %d should be %s (%s)", index, expected, why)
			end
		end
		return true
	end
	
	-- Limiting each player rate
	
	local function newLimiter(rate)
		assert(type(rate.Max) == "number" and rate.Max >= 1, "[Net] RateLimit.Max must be a number >= 1")
		assert(type(rate.Window) == "number" and rate.Window > 0, "[Net] RateLimit.Window must be a number > 0")
		return {
			Max = rate.Max,
			PerSecond = rate.Max / rate.Window,
			Buckets = {},
		}
	end

	local function allow(limiter, player)
		local now = os.clock()
		local bucket = limiter.Buckets[player]
		if not bucket then
			bucket = { Tokens = limiter.Max, Last = now }
			limiter.Buckets[player] = bucket
		end

		bucket.Tokens = math.min(limiter.Max, bucket.Tokens + (now - bucket.Last) * limiter.PerSecond)
		bucket.Last = now

		if bucket.Tokens < 1 then
			return false
		end
		bucket.Tokens -= 1
		return true
	end

	-- Handler registry --------------------------------------------------

	local handlers = {} -- [name] = handler
	local globalLimiter = newLimiter(GLOBAL_RATE_LIMIT)

	local function register(name, callback, options, isInvoke)
		checkName(name, 3)
		if type(callback) ~= "function" then
			error("[Net] Handler for " .. name .. " must be a function", 3)
		end
		if handlers[name] then
			error(string.format("[Net] %q already has a server handler (only one allowed)", name), 3)
		end

		options = options or {}
		if options.Types ~= nil and type(options.Types) ~= "table" then
			error("[Net] options.Types must be a table", 3)
		end
		if options.Types == nil then
			debugWarn("notypes:" .. name, string.format(
				"%q has no Types, so its arguments are not checked. Add Types = {...} (or {} for no arguments).",
				name
				))
		end

		local handler = {
			Name = name,
			Callback = callback,
			IsInvoke = isInvoke,
			Types = options.Types,
			MaxStringLength = options.MaxStringLength or DEFAULT_MAX_STRING_LENGTH,
			Limiter = newLimiter(options.RateLimit or DEFAULT_RATE_LIMIT),
		}
		handlers[name] = handler

		return {
			Disconnect = function()
				if handlers[name] == handler then
					handlers[name] = nil
				end
			end,
		}
	end

	-- Every incoming message passes these checks before any game code sees it
	local function accept(player, name, isInvoke, ...)
		if not allow(globalLimiter, player) then
			debugWarn("flood:" .. player.UserId, player.Name .. " is sending too many messages; dropping")
			return nil
		end
		if type(name) ~= "string" then
			return nil
		end

		local handler = handlers[name]
		if not handler then
			debugWarn("unknown:" .. name, string.format("Got %q from %s but nothing handles it", name, player.Name))
			return nil
		end
		if handler.IsInvoke ~= isInvoke then
			debugWarn("kind:" .. name, string.format(
				"%q from %s used the wrong call (%s)", name, player.Name,
				isInvoke and "InvokeServer on an event" or "FireServer on an invoke handler"
				))
			return nil
		end
		if not allow(handler.Limiter, player) then
			debugWarn("rate:" .. name .. player.UserId, string.format("%s is rate-limited on %q", player.Name, name))
			return nil
		end
		if handler.Types then
			local ok, reason = validateArgs(handler.Types, handler.MaxStringLength, ...)
			if not ok then
				debugWarn("args:" .. name .. player.UserId, string.format(
					"Rejected %q from %s: %s", name, player.Name, reason
					))
				return nil
			end
		end
		return handler
	end

	local function onServerEvent(player, name, ...)
		local handler = accept(player, name, false, ...)
		if handler then
			safeCall(name, handler.Callback, player, ...)
		end
	end

	remoteEvent.OnServerEvent:Connect(onServerEvent)
	unreliableRemoteEvent.OnServerEvent:Connect(onServerEvent)

	remoteFunction.OnServerInvoke = function(player, name, ...)
		local handler = accept(player, name, true, ...)
		if not handler then
			return nil
		end
		local results = table.pack(xpcall(handler.Callback, debug.traceback, player, ...))
		if not results[1] then
			warn(string.format("[Net] Invoke handler for %q errored:\n%s", name, tostring(results[2])))
			return nil
		end
		return table.unpack(results, 2, results.n)
	end

	Players.PlayerRemoving:Connect(function(player)
		globalLimiter.Buckets[player] = nil
		for _, handler in pairs(handlers) do
			handler.Limiter.Buckets[player] = nil
		end
	end)

	-- Public API (server) ------------------------------------------------

	function Net.Connect(name, callback, options)
		return register(name, callback, options, false)
	end

	function Net.SetInvokeHandler(name, callback, options)
		return register(name, callback, options, true)
	end

	local function isLivePlayer(player)
		return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
	end

	function Net.FireClient(player, name, ...)
		checkName(name)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			error("[Net] Net.FireClient: first argument must be a Player", 2)
		end
		if isLivePlayer(player) then
			remoteEvent:FireClient(player, name, ...)
		end
	end

	function Net.FireClients(players, name, ...)
		checkName(name)
		for _, player in ipairs(players) do
			if isLivePlayer(player) then
				remoteEvent:FireClient(player, name, ...)
			end
		end
	end

	function Net.FireAllClients(name, ...)
		checkName(name)
		remoteEvent:FireAllClients(name, ...)
	end

	function Net.FireAllClientsExcept(exceptPlayer, name, ...)
		checkName(name)
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= exceptPlayer then
				remoteEvent:FireClient(player, name, ...)
			end
		end
	end

	function Net.FireClientUnreliable(player, name, ...)
		checkName(name)
		if isLivePlayer(player) then
			unreliableRemoteEvent:FireClient(player, name, ...)
		end
	end

	function Net.FireAllClientsUnreliable(name, ...)
		checkName(name)
		unreliableRemoteEvent:FireAllClients(name, ...)
	end

	Net.FireServer = wrongSide("FireServer", "client")
	Net.FireServerUnreliable = wrongSide("FireServerUnreliable", "client")
	Net.InvokeServer = wrongSide("InvokeServer", "client")
end

--// Client

if not IS_SERVER then
	local listeners = {} -- [name] = { connection, ... }
	local queued = {} -- [name] = { packedArgs, ... }

	local function dispatch(name, ...)
		if type(name) ~= "string" then
			return
		end

		local list = listeners[name]
		if list and #list > 0 then
			for _, connection in ipairs(table.clone(list)) do
				if connection.Connected then
					task.spawn(safeCall, name, connection.Callback, ...)
				end
			end
			return
		end

		-- Nobody is listening yet: keep it for when someone connects
		local queue = queued[name]
		if not queue then
			queue = {}
			queued[name] = queue
		end
		if #queue >= MAX_QUEUED_PER_NAME then
			table.remove(queue, 1)
		end
		table.insert(queue, table.pack(...))
	end

	remoteEvent.OnClientEvent:Connect(dispatch)
	unreliableRemoteEvent.OnClientEvent:Connect(dispatch)

	-- Public API (client) ------------------------------------------------

	function Net.Connect(name, callback, options)
		checkName(name)
		if type(callback) ~= "function" then
			error("[Net] Listener for " .. name .. " must be a function", 2)
		end
		if options ~= nil then
			debugWarn("clientopts:" .. name, "Options passed to Net.Connect on the client are ignored (" .. name .. ")")
		end

		local list = listeners[name]
		if not list then
			list = {}
			listeners[name] = list
		end

		local connection = { Connected = true, Callback = callback }
		function connection:Disconnect()
			if not self.Connected then
				return
			end
			self.Connected = false
			local index = table.find(list, self)
			if index then
				table.remove(list, index)
			end
		end
		connection.Destroy = connection.Disconnect
		table.insert(list, connection)

		local queue = queued[name]
		if queue then
			queued[name] = nil
			task.defer(function()
				for _, args in ipairs(queue) do
					if connection.Connected then
						safeCall(name, callback, table.unpack(args, 1, args.n))
					end
				end
			end)
		end

		return connection
	end

	function Net.FireServer(name, ...)
		checkName(name)
		remoteEvent:FireServer(name, ...)
	end

	function Net.FireServerUnreliable(name, ...)
		checkName(name)
		unreliableRemoteEvent:FireServer(name, ...)
	end

	function Net.InvokeServer(name, ...)
		checkName(name)
		return remoteFunction:InvokeServer(name, ...)
	end

	Net.SetInvokeHandler = wrongSide("SetInvokeHandler", "server")
	Net.FireClient = wrongSide("FireClient", "server")
	Net.FireClients = wrongSide("FireClients", "server")
	Net.FireAllClients = wrongSide("FireAllClients", "server")
	Net.FireAllClientsExcept = wrongSide("FireAllClientsExcept", "server")
	Net.FireClientUnreliable = wrongSide("FireClientUnreliable", "server")
	Net.FireAllClientsUnreliable = wrongSide("FireAllClientsUnreliable", "server")
end

return Net