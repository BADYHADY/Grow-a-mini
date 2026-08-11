--!strict
-- One currency in the MVP. Adding a second one requires an actual economy
-- problem that a second currency solves -- "the shop looks empty" is not one.

export type CurrencyId = "Coins"

return {
	Currencies = {
		Coins = {
			DisplayName = "Coins",
			-- Shown abbreviated everywhere except exact prices.
			Abbreviate = true,
			StartingAmount = 0,
		},
	},

	-- Sources. Every entry here must have a matching sink below, or the economy
	-- inflates and upgrade costs stop meaning anything.
	Sources = {
		EnemyKillBase = 3, -- multiplied by the enemy's CoinMultiplier
		BossKillBase = 60,
		OfflineTrainingPerMinute = 1.2,
	},

	-- Sinks.
	Sinks = {
		-- Upgrades are the only sink in the MVP; see UpgradeConfig for the curve.
	},

	Offline = {
		-- Active play must stay the fastest route. Offline income is a reason to
		-- come back tomorrow, not a substitute for playing.
		-- Rate is expressed as a fraction of what an average active minute earns.
		EfficiencyVsActive = 0.35,
		-- Cap in hours. Long enough to cover a night's sleep and a school day,
		-- short enough that logging in daily is clearly better than weekly.
		MaxAccrualHours = 10,
		-- Below this, don't show the welcome-back screen at all -- interrupting a
		-- player who left two minutes ago is pure friction.
		MinimumHoursToShowReport = 0.25,
	},
}
