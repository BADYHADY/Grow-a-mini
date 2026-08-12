--!strict
-- The persistent player record.
--
-- Constraints inherited from ProfileStore: no gaps in numeric tables, no mixed
-- keys, no nil values inside stored tables, no Roblox instances or userdata.
-- Anything stored here must be a plain string/number/boolean/table.
--
-- SchemaVersion is bumped whenever this shape changes, and DataService owns a
-- migration for every bump. Old saves are never silently discarded.

local MiniSnapshot = require(script.Parent.MiniSnapshot)

export type Currencies = {
	Coins: number,
}

export type MiniState = {
	Level: number,
	Xp: number,
	-- Earned by training and never lost. This is the number the player watches
	-- climb above the Mini's head.
	Power: number,
	-- Health is spent in fights and refilled at the punching bag, so it persists:
	-- a Mini that left the session hurt has to be trained back up.
	Health: number,
	MaxHealth: number,
	-- The floor the current tower run is on. Runs restart from the bottom, so
	-- this is progress within a run; BestFloor is the number worth bragging about.
	TowerFloor: number,
	BestFloor: number,
	-- Every mutation the player has ever unlocked, for the Collection Book.
	UnlockedMutations: { string },
	-- The one currently applied. Empty string means none, rather than nil,
	-- because ProfileStore's reconcile does not fill nils.
	ActiveMutation: string,
}

export type Stats = {
	EnemiesKilled: number,
	BossesKilled: number,
	MutationsRolled: number,
	PlayTimeSeconds: number,
	SessionCount: number,
	HighestWave: number,
}

-- Which one-time onboarding beats the player has passed. Used both to avoid
-- replaying them and as the source of the funnel analytics.
export type Onboarding = {
	SawAwakening: boolean,
	FirstKill: boolean,
	FirstUpgrade: boolean,
	FirstAbility: boolean,
	FirstBoss: boolean,
	FirstMutation: boolean,
}

export type Data = {
	SchemaVersion: number,
	Currencies: Currencies,
	-- upgradeId -> level. Absent means level 0.
	Upgrades: { [string]: number },
	Mini: MiniState,
	Stats: Stats,
	Onboarding: Onboarding,
	FirstSeenUnix: number,
	LastSeenUnix: number,
	-- Captured the first time a Mini is built for this player, and never
	-- overwritten. This is what makes "Day 1 vs Day 30" possible later -- if we
	-- do not save it from the very first release, early players lose that history
	-- permanently.
	OriginSnapshot: MiniSnapshot.Snapshot?,
}

return {}
