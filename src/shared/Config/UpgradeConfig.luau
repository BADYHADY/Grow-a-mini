--!strict
-- Upgrade definitions and the cost curve.
--
-- The curve is a formula rather than a hand-written table so we can retune the
-- whole game's pacing by changing two numbers, and so nobody has to maintain a
-- 50-row spreadsheet in Luau.

export type UpgradeId = "MiniDamage" | "AttackSpeed" | "CritChance" | "CoinGain"

export type Upgrade = {
	Id: UpgradeId,
	DisplayName: string,
	Description: string,
	MaxLevel: number,
	BaseCost: number,
	-- cost(level) = BaseCost * CostGrowth ^ (level - 1)
	CostGrowth: number,
	-- Flat amount added to the stat per level. Additive, not multiplicative:
	-- multiplicative upgrade stacks are how simulators end up with 1e18 damage.
	PerLevel: number,
	-- Levels at which the Mini visibly changes. Progression the player cannot
	-- see is progression they do not feel.
	VisualBreakpoints: { number },
}

local Upgrades: { [UpgradeId]: Upgrade } = {
	MiniDamage = {
		Id = "MiniDamage",
		DisplayName = "Mini Damage",
		Description = "Your Mini hits harder.",
		MaxLevel = 50,
		BaseCost = 15,
		CostGrowth = 1.18,
		PerLevel = 4,
		VisualBreakpoints = { 5, 15, 30, 50 },
	},

	AttackSpeed = {
		Id = "AttackSpeed",
		DisplayName = "Attack Speed",
		Description = "Your Mini swings faster.",
		MaxLevel = 25,
		BaseCost = 40,
		CostGrowth = 1.26,
		PerLevel = 0.06,
		VisualBreakpoints = { 10, 25 },
	},

	CritChance = {
		Id = "CritChance",
		DisplayName = "Crit Chance",
		Description = "Chance to land a critical hit.",
		MaxLevel = 20,
		BaseCost = 75,
		CostGrowth = 1.3,
		PerLevel = 0.015,
		VisualBreakpoints = { 20 },
	},

	CoinGain = {
		Id = "CoinGain",
		DisplayName = "Coin Gain",
		Description = "Earn more coins per kill.",
		MaxLevel = 30,
		BaseCost = 60,
		CostGrowth = 1.22,
		PerLevel = 0.05,
		VisualBreakpoints = {},
	},
}

-- Order the shop lists them in. Damage first: it is the one upgrade a new
-- player understands without reading anything.
local DisplayOrder: { UpgradeId } = { "MiniDamage", "AttackSpeed", "CritChance", "CoinGain" }

local UpgradeConfig = {
	Upgrades = Upgrades,
	DisplayOrder = DisplayOrder,
}

-- Cost to go from `currentLevel` to `currentLevel + 1`. Returns nil at max level.
function UpgradeConfig.getCost(id: UpgradeId, currentLevel: number): number?
	local upgrade = Upgrades[id]
	if not upgrade or currentLevel >= upgrade.MaxLevel then
		return nil
	end
	local raw = upgrade.BaseCost * upgrade.CostGrowth ^ currentLevel
	-- Round to something a 10-year-old can compare at a glance.
	if raw < 100 then
		return math.floor(raw + 0.5)
	elseif raw < 10_000 then
		return math.floor(raw / 5 + 0.5) * 5
	else
		return math.floor(raw / 100 + 0.5) * 100
	end
end

-- Total stat contribution of an upgrade at a given level.
function UpgradeConfig.getBonus(id: UpgradeId, level: number): number
	local upgrade = Upgrades[id]
	if not upgrade then
		return 0
	end
	return upgrade.PerLevel * math.clamp(level, 0, upgrade.MaxLevel)
end

return UpgradeConfig
