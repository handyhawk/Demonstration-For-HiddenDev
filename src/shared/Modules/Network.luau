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