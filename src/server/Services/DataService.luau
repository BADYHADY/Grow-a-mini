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
local MiniConfig = require(Shared.Config.MiniConfig)

local STORE_NAME = "PlayerData"
local CURRENT_SCHEMA_VERSION = 3

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
		Power = 0,
		-- A new Mini wakes up weak and trains its way up. Existing profiles are
		-- migrated to FULL health instead -- see MIGRATIONS[2].
		Health = math.floor(
			MiniConfig.BaseStats.Health * MiniConfig.Training.StartingHealthFraction
		),
		MaxHealth = MiniConfig.BaseStats.Health,
		TowerFloor = MiniConfig.Tower.StartFloor,
		BestFloor = 0,
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
local MIGRATIONS: { [number]: (data: any) -> () } = {
-- Baseline migration for profiles created before SchemaVersion existed.
-- Reconcile runs AFTER migrations and fills the normal V1 defaults.
[1] = function(_data: any)
-- No structural transform required for the V1 baseline.
end,

-- V0.4: training gave the Mini Power and Health. Reconcile fills the new
-- fields with the template defaults, but a V1 profile has to start at FULL
-- health rather than at whatever a later balance pass makes the default --
-- an existing player must never log in to a hurt Mini they never fought with.
[2] = function(data: any)
local mini = data.Mini

if type(mini) ~= "table" then
return
end

mini.Power = 0
mini.MaxHealth = MiniConfig.BaseStats.Health
mini.Health = mini.MaxHealth
end,

-- V0.5: the tower. Reconcile fills the new floor fields, but say so explicitly
-- so a profile from before the tower existed cannot start mid-run.
[3] = function(data: any)
local mini = data.Mini

if type(mini) ~= "table" then
return
end

mini.TowerFloor = MiniConfig.Tower.StartFloor
mini.BestFloor = 0
end,
}

local DataService = {}

-- (player, profile)
DataService.ProfileLoaded = Signal.new()
-- (player, profile) -- fires before the session ends, while data is still writable
DataService.ProfileReleasing = Signal.new()

local store
local profiles: { [Player]: any } = {}

local function migrate(player: Player, data: any)
local rawVersion = data.SchemaVersion

local from = 0
if type(rawVersion) == "number" then
from = math.max(0, math.floor(rawVersion))
end

assert(
from <= CURRENT_SCHEMA_VERSION,
`Profile schema v{from} is newer than server schema v{CURRENT_SCHEMA_VERSION} (player {player.UserId})`
)

local version = from

while version < CURRENT_SCHEMA_VERSION do
local target = version + 1
local migration = MIGRATIONS[target]

assert(
migration,
`No migration to schema v{target} (player {player.UserId})`
)

migration(data)
data.SchemaVersion = target
version = target
end

if from ~= version and GameConfig.DebugLogging then
print(`[DataService] migrated {player.Name}: v{from} -> v{version}`)
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

-- Migrate BEFORE Reconcile. If Reconcile wrote the newest SchemaVersion
-- into an old profile first, we would lose the information required to
-- know which migrations that profile still needs.
local prepared, prepareErr = pcall(function()
migrate(player, profile.Data)
profile:Reconcile()
end)

if not prepared then
warn(`[DataService] failed to prepare profile for {player.UserId}: {prepareErr}`)
profile:EndSession()
player:Kick("Your save could not be updated safely. Please rejoin.")
return
end

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
