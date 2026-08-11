--!strict
-- Enemy definitions. Adding an enemy is a table entry -- never a code change.
--
-- Enemies have no Humanoid. Health lives in an attribute and movement is a
-- CFrame lerp, because 40 Humanoids per server is the single most expensive
-- thing we could possibly do on a phone.

export type EnemyId = "TrainingDummy" | "GymRat" | "AngryKettlebell" | "TrainingSergeant"

export type Enemy = {
	Id: EnemyId,
	DisplayName: string,
	Health: number,
	Damage: number,
	MoveSpeed: number, -- 0 means stationary
	AttacksPerSecond: number,
	CoinMultiplier: number, -- multiplies EconomyConfig.Sources.EnemyKillBase
	XpReward: number,
	IsBoss: boolean,
	-- Name of the model inside ReplicatedStorage.Shared assets folder, resolved
	-- at spawn time. Missing models fall back to a grey block so a bad asset
	-- reference never takes the server down.
	ModelName: string,
	-- How many can exist at once, server-wide. Guards the 40-enemy budget.
	MaxConcurrent: number,
}

local Enemies: { [EnemyId]: Enemy } = {
	TrainingDummy = {
		Id = "TrainingDummy",
		DisplayName = "Training Dummy",
		Health = 30,
		Damage = 0, -- the very first enemy never hits back
		MoveSpeed = 0,
		AttacksPerSecond = 0,
		CoinMultiplier = 1,
		XpReward = 2,
		IsBoss = false,
		ModelName = "TrainingDummy",
		MaxConcurrent = 24,
	},

	GymRat = {
		Id = "GymRat",
		DisplayName = "Gym Rat",
		Health = 90,
		Damage = 4,
		MoveSpeed = 10,
		AttacksPerSecond = 0.7,
		CoinMultiplier = 2.5,
		XpReward = 6,
		IsBoss = false,
		ModelName = "GymRat",
		MaxConcurrent = 20,
	},

	AngryKettlebell = {
		Id = "AngryKettlebell",
		DisplayName = "Angry Kettlebell",
		Health = 220,
		Damage = 9,
		MoveSpeed = 6,
		AttacksPerSecond = 0.5,
		CoinMultiplier = 5,
		XpReward = 15,
		IsBoss = false,
		ModelName = "AngryKettlebell",
		MaxConcurrent = 10,
	},

	TrainingSergeant = {
		Id = "TrainingSergeant",
		DisplayName = "Training Sergeant",
		Health = 900,
		Damage = 14,
		MoveSpeed = 8,
		AttacksPerSecond = 0.6,
		CoinMultiplier = 20,
		XpReward = 80,
		IsBoss = true,
		ModelName = "TrainingSergeant",
		MaxConcurrent = 1,
	},
}

-- enemyId -> how many of it spawn in that wave.
export type Wave = { [EnemyId]: number }

-- Wave composition for the training yard. Index is the wave number. Waves
-- repeat from the last entry with a scaling multiplier once exhausted.
local TrainingWaves: { Wave } = {
	{ TrainingDummy = 1 },
	{ TrainingDummy = 3 },
	{ TrainingDummy = 2, GymRat = 1 },
	{ GymRat = 3 },
	{ GymRat = 2, AngryKettlebell = 1 },
	{ TrainingSergeant = 1 },
}

return {
	Enemies = Enemies,
	TrainingWaves = TrainingWaves,

	-- Health/damage multiplier applied per wave loop past the last defined wave.
	EndlessScaling = 1.35,
}
