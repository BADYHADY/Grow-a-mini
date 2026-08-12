--!nonstrict
-- Every remote in the game is declared in DEFINITIONS below, and every
-- client->server handler must go through Remotes.bind, which will not accept a
-- registration without a rate limit.
--
-- That is deliberate. Rate limiting by convention gets forgotten on the one
-- remote that matters; rate limiting baked into the API shape does not. Same for
-- direction: a remote declared ServerToClient cannot be bound on the server, so
-- a typo cannot quietly open a presentation channel to client traffic.
--
-- Handlers still have to validate their own payloads. The limiter only bounds
-- how often a client can lie to us, not whether it is lying.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "Remotes"

-- name -> direction
local DEFINITIONS = {
	-- Client to server. Intents only: the client asks, the server decides.
	BuyUpgrade = "ClientToServer",
	-- "Follow" | "Train" | "Tower" -- the player telling their Mini where to be.
	-- Intent only: the server decides whether it is allowed and what it means.
	MiniCommand = "ClientToServer",
	ActivateAbility = "ClientToServer",
	RollMutation = "ClientToServer",
	ClaimOfflineReward = "ClientToServer",

	-- Server to client. State and presentation.
	ProfileSync = "ServerToClient",
	CurrencyChanged = "ServerToClient",
	MiniReady = "ServerToClient",
	MiniAppearanceChanged = "ServerToClient",
	CombatFeedback = "ServerToClient",
	Announcement = "ServerToClient",
}

export type RateLimit = {
	-- Sustained requests allowed per second.
	perSecond: number,
	-- Short burst allowed above the sustained rate. Defaults to 2x perSecond,
	-- because real players tap buttons in bursts and a hard cap feels broken.
	burst: number?,
}

local Remotes = {}

-- Fired server-side when a request is dropped. AnalyticsService listens to this
-- so rejections show up in the funnel instead of vanishing into Output.
Remotes.Rejected = Signal.new()

local folder: Folder
local events: { [string]: RemoteEvent } = {}

-- [Player][remoteName] = { tokens: number, last: number }
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}

local function assertDeclared(name: string, expected: string)
	local direction = DEFINITIONS[name]
	assert(direction, `Remote "{name}" is not declared in Remotes.DEFINITIONS`)
	assert(
		direction == expected,
		`Remote "{name}" is declared {direction} but was used as {expected}`
	)
end

-- Token bucket. Refills continuously rather than resetting on a window edge, so
-- a player cannot double their allowance by straddling a boundary.
local function allow(player: Player, name: string, limit: RateLimit): boolean
	local capacity = limit.burst or limit.perSecond * 2

	local playerBuckets = buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end

	local bucket = playerBuckets[name]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = capacity, last = now }
		playerBuckets[name] = bucket
	end

	bucket.tokens = math.min(capacity, bucket.tokens + (now - bucket.last) * limit.perSecond)
	bucket.last = now

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

local function build()
	if IS_SERVER then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME

		for name in DEFINITIONS do
			local event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
			events[name] = event
		end

		folder.Parent = ReplicatedStorage

		Players.PlayerRemoving:Connect(function(player)
			buckets[player] = nil
		end)
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
		for name in DEFINITIONS do
			events[name] = folder:WaitForChild(name) :: RemoteEvent
		end
	end
end

build()

--[[ Server ]]

-- Register the handler for a client intent. `limit` is required.
function Remotes.bind(name: string, limit: RateLimit, handler: (player: Player, ...any) -> ())
	assert(IS_SERVER, "Remotes.bind is server only")
	assertDeclared(name, "ClientToServer")
	assert(limit and limit.perSecond and limit.perSecond > 0, `Remote "{name}" needs a positive perSecond rate limit`)

	events[name].OnServerEvent:Connect(function(player, ...)
		if not allow(player, name, limit) then
			Remotes.Rejected:Fire(player, name, "RateLimited")
			return
		end

		-- A throwing handler must not kill the connection for everyone else.
		local ok, err = pcall(handler, player, ...)
		if not ok then
			Remotes.Rejected:Fire(player, name, "HandlerError")
			warn(`[Remotes] handler for "{name}" errored: {err}`)
		end
	end)
end

function Remotes.fire(player: Player, name: string, ...)
	assert(IS_SERVER, "Remotes.fire is server only")
	assertDeclared(name, "ServerToClient")
	events[name]:FireClient(player, ...)
end

function Remotes.fireAll(name: string, ...)
	assert(IS_SERVER, "Remotes.fireAll is server only")
	assertDeclared(name, "ServerToClient")
	events[name]:FireAllClients(...)
end

--[[ Client ]]

function Remotes.on(name: string, handler: (...any) -> ())
	assert(not IS_SERVER, "Remotes.on is client only")
	assertDeclared(name, "ServerToClient")
	return events[name].OnClientEvent:Connect(handler)
end

function Remotes.send(name: string, ...)
	assert(not IS_SERVER, "Remotes.send is client only")
	assertDeclared(name, "ClientToServer")
	events[name]:FireServer(...)
end

Remotes.DEFINITIONS = DEFINITIONS

return Remotes
