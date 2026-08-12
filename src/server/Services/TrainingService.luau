--!nonstrict
-- V0.5: what a punch is actually WORTH.
--
-- The punching bag is the feeder. Every landed punch heals the Mini, makes it
-- permanently stronger, drops a coin, and fills an XP bar that pops a level
-- every few hits. Fill the health bar and the Mini stops working and starts
-- mooching around the dojo -- which is the only "ready" signal the player gets.
--
-- The client never reports a punch. Server and client both count punches off the
-- same shared clock (see Shared.Util.PunchClock), so a hacked client can throw
-- as many fists as it likes on screen and still earn exactly what the clock says.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MiniConfig = require(Shared.Config.MiniConfig)
local UpgradeConfig = require(Shared.Config.UpgradeConfig)
local PunchClock = require(Shared.Util.PunchClock)
local Remotes = require(Shared.Net.Remotes)

local TRAINING = MiniConfig.Training

-- Power is awarded in whole punches, so checking four times a second is plenty
-- even at high attack speeds, and costs nothing with twenty players.
local TICK_SECONDS = 0.25

local TrainingService = {}

local AnalyticsService
local DataService
local MiniBaseService
local MiniService

type Session = {
	epoch: number,
	paidPunches: number,
	publishedTo: Model?,
	-- How many punches this bag survives. Sized once per session against how
	-- much health the Mini has to put back, so the bag gives out at about the
	-- same time the Mini does -- see MiniConfig.Training.Wear.
	durability: number,
}

local sessions: { [Player]: Session } = {}

--[[ Stats ]]

-- XP needed to go from `level` to the next one. A formula rather than a table so
-- the whole pacing curve is two numbers in MiniConfig.
function TrainingService.xpForLevel(level: number): number
	return math.floor(
		TRAINING.XpForFirstLevel * TRAINING.XpGrowthPerLevel ^ (level - 1)
	)
end

-- How much one punch is worth, given how good the bag is. This is the number the
-- tower's coins are spent to raise.
local function bagMultiplier(data): number
	local level = data.Upgrades.PunchingBag or 0
	return 1 + UpgradeConfig.getBonus("PunchingBag", level)
end

-- Last value pushed to each client, so a per-punch tick does not fire a remote
-- for a number that has not moved.
local publishedCoins: { [Player]: number } = {}

function TrainingService.publish(player: Player, mini: Model?)
	local data = DataService.getData(player)

	if not data then
		return
	end

	-- Coins are the PLAYER's, not the fighter's: they go to that player's HUD
	-- rather than onto a model every client can read.
	if publishedCoins[player] ~= data.Currencies.Coins then
		publishedCoins[player] = data.Currencies.Coins
		Remotes.fire(player, "CurrencyChanged", "Coins", data.Currencies.Coins)
	end

	if not mini then
		return
	end

	local stats = data.Mini

	mini:SetAttribute("Level", stats.Level)
	mini:SetAttribute("Power", stats.Power)
	mini:SetAttribute("Health", stats.Health)
	mini:SetAttribute("MaxHealth", stats.MaxHealth)
	mini:SetAttribute("Xp", stats.Xp)
	mini:SetAttribute("XpForLevel", TrainingService.xpForLevel(stats.Level))
	mini:SetAttribute("TowerFloor", stats.TowerFloor)
	-- Still published, but nothing draws a label from it any more: the health
	-- bar's colour is the readiness signal. Kept because the SERVER uses the
	-- same idea to decide when the Mini stops working.
	mini:SetAttribute("ReadyToFight", stats.Health >= stats.MaxHealth)

	local session = sessions[player]
	if session then
		session.publishedTo = mini
	end
end

-- Returns how many levels were gained, so the caller can decide whether that is
-- worth an announcement.
local function applyLevels(player: Player, stats): number
	local gained = 0

	while stats.Xp >= TrainingService.xpForLevel(stats.Level) do
		stats.Xp -= TrainingService.xpForLevel(stats.Level)
		stats.Level += 1
		gained += 1

		stats.MaxHealth += TRAINING.HealthPerLevel
		stats.Power += TRAINING.PowerPerLevel
		-- Paid out as health too, so the bar visibly jumps instead of just
		-- getting longer.
		stats.Health = math.min(
			stats.MaxHealth,
			stats.Health + TRAINING.HealthBoostPerLevel
		)
	end

	if gained > 0 then
		-- The Mini physically grows. This is the entire reason a level is worth
		-- earning: you can see it on the fighter, not just on the card.
		MiniService.applyGrowth(player, stats.Level)

		AnalyticsService.track(player, "MiniLevelUp", {
			level = stats.Level,
			power = stats.Power,
		})

		if GameConfig.DebugLogging then
			print(`[TrainingService] {player.Name} Mini reached level {stats.Level}`)
		end
	end

	return gained
end

--[[ Bag wear ]]

-- The bag's remaining condition, 0..1, published on the bag model so every
-- client can draw it. The server owns it for the same reason it owns everything
-- else: it is the visible face of a payout the client must not be able to fake.
local function publishCondition(player: Player, condition: number)
	local bag = MiniBaseService.getBagModel(player)

	if bag then
		bag:SetAttribute("Condition", math.clamp(condition, 0, 1))
	end
end

-- How many punches it takes to put this Mini back to full, at the value one
-- punch currently has. This is what the bag is sized against.
local function durabilityFor(data): number
	local stats = data.Mini
	local perPunch = math.max(
		1,
		math.floor(TRAINING.HealthPerPunch * bagMultiplier(data))
	)
	local needed = math.max(0, stats.MaxHealth - stats.Health) / perPunch

	return math.max(
		TRAINING.Wear.MinDurabilityPunches,
		math.ceil(needed * TRAINING.Wear.DurabilityMargin)
	)
end

local function award(player: Player, data, punches: number)
	local stats = data.Mini
	local multiplier = bagMultiplier(data)

	stats.Power += math.floor(punches * TRAINING.PowerPerPunch * multiplier)
	stats.Xp += math.floor(punches * TRAINING.XpPerPunch * multiplier)

	-- Training tops the Mini back up. It cannot push past the ceiling, which is
	-- what makes "full health" a meaningful moment to send it to a fight.
	stats.Health = math.min(
		stats.MaxHealth,
		stats.Health + math.floor(punches * TRAINING.HealthPerPunch * multiplier)
	)

	data.Currencies.Coins += math.floor(punches * TRAINING.CoinsPerPunch)

	applyLevels(player, stats)

	AnalyticsService.trackOnce(player, "FirstTrainingPunch")
end

local function step(player: Player)
	local data = DataService.getData(player)

	if not data or type(data.Mini) ~= "table" then
		return
	end

	local mini = MiniService.get(player)
	local epoch, rate = MiniService.getPunchClock(player, "Training")
	local session = sessions[player]

	local function republishIfStale()
		if session and session.publishedTo ~= mini then
			TrainingService.publish(player, mini)
		end
	end

	if not epoch or not rate then
		-- Not training. The bag is left alone, so it repairs itself: a Mini out
		-- at the tower is away for far longer than a repair takes, and a bag the
		-- player has to wait on would be a wall in the middle of the loop.
		if session then
			sessions[player] = nil
			publishCondition(player, 1)
		end

		-- Still republish if the Mini was rebuilt, or the stats above a
		-- following Mini would read as zero.
		republishIfStale()
		return
	end

	-- ANTI-FARM. Training is the reward for having SPENT health in a fight; a
	-- Mini that is already full earns nothing, however many times the player
	-- toggles FOLLOW ME / GO TRAIN. Enforced here rather than in the UI,
	-- because the UI is the client's and the client is assumed hostile.
	if data.Mini.Health >= data.Mini.MaxHealth then
		if session then
			sessions[player] = nil
			publishCondition(player, 1)
		end

		MiniService.enterReady(player)
		republishIfStale()
		return
	end

	if not session or session.epoch ~= epoch then
		session = {
			epoch = epoch,
			paidPunches = 0,
			publishedTo = nil,
			durability = durabilityFor(data),
		}
		sessions[player] = session
		publishCondition(player, 1)
	end

	local landed = PunchClock.landed(epoch, rate)
	local unpaid = landed - session.paidPunches

	if unpaid <= 0 then
		republishIfStale()
		return
	end

	session.paidPunches = landed
	award(player, data, unpaid)

	-- A level gained mid-cycle raises the health ceiling, so the Mini now needs
	-- more punches than the bag was sized for. Extend it rather than let the bag
	-- give out while the fighter still has a bar to fill.
	session.durability = math.max(
		session.durability,
		session.paidPunches + durabilityFor(data)
	)
	TrainingService.publish(player, mini)

	-- Every punch visibly costs the bag something. This is the whole point of
	-- the feeder: the resource is spent on screen, not in a stock counter.
	publishCondition(player, 1 - landed / session.durability)

	-- Full. Down tools and go and stand about -- that is the cue for the player
	-- to send it back to the tower.
	if data.Mini.Health >= data.Mini.MaxHealth then
		MiniService.enterReady(player)
	end
end

--[[ Upgrades ]]

local function onBuyUpgrade(player: Player, upgradeId: unknown)
	if type(upgradeId) ~= "string" then
		return
	end

	local upgrade = UpgradeConfig.Upgrades[upgradeId]
	local data = DataService.getData(player)

	if not upgrade or not data then
		return
	end

	local level = data.Upgrades[upgradeId] or 0
	local cost = UpgradeConfig.getCost(upgradeId, level)

	if not cost or data.Currencies.Coins < cost then
		return
	end

	data.Currencies.Coins -= cost
	data.Upgrades[upgradeId] = level + 1

	AnalyticsService.track(player, "UpgradePurchased", {
		upgradeId = upgradeId,
		level = level + 1,
		cost = cost,
	})

	TrainingService.publish(player, MiniService.get(player))

	if GameConfig.DebugLogging then
		print(`[TrainingService] {player.Name} bought {upgradeId} level {level + 1}`)
	end
end

-- Keeps the post in front of the player honest about what the next level costs.
local function refreshBagPrompt(player: Player, base: Model)
	local post = base:FindFirstChild("BagPost")
	local prompt = post and post:FindFirstChild("BagPrompt")
	local data = DataService.getData(player)

	if not prompt or not data then
		return
	end

	local level = data.Upgrades.PunchingBag or 0
	local cost = UpgradeConfig.getCost("PunchingBag", level)

	prompt.ObjectText = `PUNCHING BAG LV.{level + 1}`
	prompt.ActionText = if cost then `UPGRADE  ${cost}` else "MAXED"
	prompt.Enabled = cost ~= nil
end

local function bindBagPrompt(player: Player, base: Model)
	local post = base:FindFirstChild("BagPost")
	local prompt = post and post:FindFirstChild("BagPrompt")

	if not prompt then
		return
	end

	-- The base is built before the profile finishes loading, so the first
	-- refresh has no price to show. Do it again when the data lands.
	if DataService.getData(player) then
		refreshBagPrompt(player, base)
	else
		local connection
		connection = DataService.ProfileLoaded:Connect(function(loaded: Player)
			if loaded ~= player then
				return
			end

			connection:Disconnect()
			refreshBagPrompt(player, base)
		end)
	end

	-- ProximityPrompt.Triggered is a server event with a server-side distance
	-- check, so this needs no remote and cannot be fired by a fake client.
	prompt.Triggered:Connect(function(triggeredBy: Player)
		if triggeredBy ~= player then
			return
		end

		onBuyUpgrade(triggeredBy, "PunchingBag")
		refreshBagPrompt(player, base)
	end)
end

function TrainingService.Init(registry)
	AnalyticsService = registry.AnalyticsService
	DataService = registry.DataService
	MiniBaseService = registry.MiniBaseService
	MiniService = registry.MiniService
end

function TrainingService.Start()
	MiniBaseService.BaseCreated:Connect(bindBagPrompt)

	-- Bases for players who were already in the server are built during
	-- MiniBaseService.Start, which runs before this one. Without this pass their
	-- prompt is furniture that does nothing.
	for _, player in Players:GetPlayers() do
		local base = MiniBaseService.getBase(player)

		if base then
			bindBagPrompt(player, base)
		end
	end

	-- The HUD starts at zero and would stay there until the first punch landed,
	-- which is wrong for a returning player who already has money.
	DataService.ProfileLoaded:Connect(function(player: Player)
		local data = DataService.getData(player)

		-- A returning player's Mini is already whatever size their levels earned;
		-- it must not start over at beginner scale.
		if data then
			MiniService.applyGrowth(player, data.Mini.Level)
		end

		TrainingService.publish(player, MiniService.get(player))
	end)

	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
		publishedCoins[player] = nil
	end)

	-- Buying is cheap to spam and cheap to serve, but not free: one purchase per
	-- prompt press is the honest rate.
	Remotes.bind("BuyUpgrade", { perSecond = 4 }, onBuyUpgrade)

	local accumulated = 0

	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt

		if accumulated < TICK_SECONDS then
			return
		end

		accumulated = 0

		for _, player in Players:GetPlayers() do
			step(player)
		end
	end)
end

-- Used by the tower: a fight spends what training filled up.
function TrainingService.getStats(player: Player)
	local data = DataService.getData(player)
	return data and data.Mini or nil
end

return TrainingService
