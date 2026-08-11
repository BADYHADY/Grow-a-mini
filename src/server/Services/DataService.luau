--!nonstrict
-- Owns every read and write of persistent player data.
--
-- No other service may touch ProfileStore directly. That single rule is what
-- keeps session locking, schema migration and save-on-leave a one-file problem
-- instead of a bug that shows up in production six months from now.
--
-- Schema changes: bump CURRENT_SCHEMA_VERSION, add the matching entry to
-- MIGRATIONS, and never delete a player's data because its shape is old.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProfileStore = require(Shared.Packages.ProfileStore)
local Signal = require(Shared.Util.Signal)
local GameConfig = require(Shared.Config.GameConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)

local STORE_NAME = "PlayerData"
local CURRENT_SCHEMA_VERSION = 1

-- Studio runs against ProfileStore's in-memory mock so iteration never burns
-- live DataStore budget or corrupts real saves. Note the mock does NOT survive
-- stopping and restarting Play -- it lives in the module, and the module is
-- reloaded each run. To test real persistence end to end, set this true AND
-- enable Game Settings -> Security -> Studio Access to API Services.
local USE_LIVE_DATA_IN_STUDIO = false

local TEMPLATE = {
	SchemaVersion = CURRENT_SCHEMA_VERSION,

	Currencies = {
		Coins = EconomyConfig.Currencies.Coins.StartingAmount,
	},

	Upgrades = {},

	Mini = {
		Level = 1,
		Xp = 0,
		UnlockedMutations = {},
		ActiveMutation = "",
	},

	Stats = {
		EnemiesKilled = 0,
		BossesKilled = 0,
		MutationsRolled = 0,
		PlayTimeSeconds = 0,
		SessionCount = 0,
		HighestWave = 0,
	},

	Onboarding = {
		SawAwakening = false,
		FirstKill = false,
		FirstUpgrade = false,
		FirstAbility = false,
		FirstBoss = false,
		FirstMutation = false,
	},

	FirstSeenUnix = 0,
	LastSeenUnix = 0,
}

-- Keyed by the version being migrated TO. Each function mutates data in place
-- and must be safe to run on data that has never seen the newer fields.
--
-- Example for the next bump:
--   [2] = function(data) data.Cosmetics = { OwnedAuras = {} } end,
local MIGRATIONS: { [number]: (data: any) -> () } = {}

local DataService = {}

-- (player, profile)
DataService.ProfileLoaded = Signal.new()
-- (player, profile) -- fires before the session ends, while data is still writable
DataService.ProfileReleasing = Signal.new()

local store
local profiles: { [Player]: any } = {}

local function migrate(player: Player, data: any)
	local from = data.SchemaVersion or 1

	while data.SchemaVersion < CURRENT_SCHEMA_VERSION do
		local target = data.SchemaVersion + 1
		local migration = MIGRATIONS[target]

		-- Refusing to load is the right failure here. Guessing at a missing
		-- migration is how save files get silently mangled.
		assert(migration, `No migration to schema v{target} (player {player.UserId})`)

		migration(data)
		data.SchemaVersion = target
	end

	if from ~= data.SchemaVersion and GameConfig.DebugLogging then
		print(`[DataService] migrated {player.Name}: v{from} -> v{data.SchemaVersion}`)
	end
end

local function onPlayerAdded(player: Player)
	local profile = store:StartSessionAsync(`Player_{player.UserId}`, {
		-- Stop trying to acquire the session if they already left.
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		player:Kick("Could not load your save. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId) -- GDPR association
	profile:Reconcile() -- fill in fields added to TEMPLATE since their last save
	migrate(player, profile.Data)

	profile.OnSessionEnd:Connect(function()
		-- Only a *surprise* session end warrants a kick. A normal leave clears
		-- the entry before ending the session, so this check distinguishes
		-- "another server stole the lock" from "they closed the game".
		if profiles[player] ~= profile then
			return
		end
		profiles[player] = nil
		-- Playing on without a profile would silently discard everything they
		-- do next, which is worse than an honest rejoin prompt.
		player:Kick("Your save was opened somewhere else. Please rejoin.")
	end)

	-- They may have left while we were loading.
	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	local now = os.time()
	if profile.Data.FirstSeenUnix == 0 then
		profile.Data.FirstSeenUnix = now
	end
	profile.Data.Stats.SessionCount += 1

	profiles[player] = profile
	DataService.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end

	DataService.ProfileReleasing:Fire(player, profile)

	-- LastSeenUnix is what offline training accrues from, so it has to be the
	-- last thing written before the session closes.
	profile.Data.LastSeenUnix = os.time()

	profiles[player] = nil
	profile:EndSession()
end

--[[ Public API ]]

-- The live profile, or nil if it has not loaded yet or the player is leaving.
-- Callers must handle nil -- there is always a window where a player exists and
-- their profile does not.
function DataService.get(player: Player): any?
	return profiles[player]
end

function DataService.getData(player: Player): any?
	local profile = profiles[player]
	return profile and profile.Data or nil
end

-- Yields until the profile is available. Returns nil on timeout or if the
-- player leaves first.
function DataService.waitFor(player: Player, timeout: number?): any?
	local deadline = os.clock() + (timeout or 10)

	while os.clock() < deadline do
		local profile = profiles[player]
		if profile then
			return profile
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(0.1)
	end

	return nil
end

function DataService.Init()
	store = ProfileStore.New(STORE_NAME, TEMPLATE)

	if RunService:IsStudio() and not USE_LIVE_DATA_IN_STUDIO then
		store = store.Mock
		if GameConfig.DebugLogging then
			print("[DataService] using mock store (Studio)")
		end
	end
end

function DataService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Players who joined before this service finished starting.
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- ProfileStore handles its own BindToClose for in-flight writes, but we
	-- still end each session explicitly so LastSeenUnix is correct on shutdown.
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			onPlayerRemoving(player)
		end
	end)
end

return DataService
