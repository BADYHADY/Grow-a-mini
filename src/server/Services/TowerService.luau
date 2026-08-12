--!nonstrict
-- V0.5: the other half of the loop.
--
-- The player presses one button. The Mini walks to the pit, clears a few floors,
-- takes a beating, drops, and walks home to the bag on its own. Coins come out
-- of the floors it cleared; the bag turns those coins back into Power. That
-- round trip IS the game.
--
-- Nothing here is player-controlled beyond the decision to send. The Mini is the
-- fighter; the player is the coach.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MiniConfig = require(Shared.Config.MiniConfig)
local PunchClock = require(Shared.Util.PunchClock)
local Format = require(Shared.Util.Format)

local TOWER = MiniConfig.Tower

-- How long the Mini is left walking home before it gets back on the bag. The
-- walk itself is client-side; this is just when the payout clock restarts.
-- Backstop only. The walk home normally ends when the Mini arrives; this stops
-- a fighter wedged on some piece of geometry from never training again.
local WALK_HOME_TIMEOUT = 45.0

local TowerService = {}

local AnalyticsService
local DataService
local MiniBaseService
local MiniService
local TrainingService

type Run = {
	floor: number,
	enemyHealth: number,
	enemyMaxHealth: number,
	model: Model?,
	paidPunches: number,
	epoch: number?,
	-- Set while a cleared floor is being celebrated, or while the Mini is down.
	pausedUntil: number,
	finished: boolean,
}

local runs: { [Player]: Run } = {}

--[[ Floor maths ]]

local function enemyHealth(floor: number): number
	return math.floor(TOWER.EnemyHealthBase * TOWER.EnemyHealthGrowth ^ (floor - 1))
end

local function enemyDamage(floor: number): number
	return TOWER.EnemyDamageBase * TOWER.EnemyDamageGrowth ^ (floor - 1)
end

local function floorReward(floor: number): number
	return math.floor(TOWER.CoinsBase * TOWER.CoinsGrowth ^ (floor - 1))
end

--[[ The opponent ]]

-- Deliberately crude: a silhouette with a health bar. The Mini is the thing
-- worth looking at, and a detailed enemy would only compete with it.
local function buildEnemy(player: Player, floor: number, spot: CFrame): Model
	local model = Instance.new("Model")
	model.Name = `TowerEnemy_{player.UserId}`

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(0.55, 0.75, 0.45)
	body.Color = Color3.fromRGB(48, 46, 58)
	body.Material = Enum.Material.SmoothPlastic
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CFrame = spot * CFrame.new(0, 0.38, 0)
	body.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(0.42, 0.42, 0.42)
	head.Color = Color3.fromRGB(150, 44, 44)
	head.Material = Enum.Material.SmoothPlastic
	head.Anchored = true
	head.CanCollide = false
	head.CanQuery = false
	head.CFrame = spot * CFrame.new(0, 0.95, 0)
	head.Parent = model

	model.PrimaryPart = body

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EnemyPlate"
	billboard.Size = UDim2.fromScale(3.0, 1.1)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 0.85, 0)
	billboard.MaxDistance = 90
	billboard.Adornee = head
	billboard.Parent = model

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.55)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 120, 120)
	title.Text = `FLOOR {floor}`
	title.Parent = billboard

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Thickness = 3
	titleStroke.Color = Color3.fromRGB(16, 16, 20)
	titleStroke.Parent = title

	local bar = Instance.new("Frame")
	bar.Name = "HealthBar"
	bar.Position = UDim2.fromScale(0.15, 0.62)
	bar.Size = UDim2.fromScale(0.7, 0.24)
	bar.BackgroundColor3 = Color3.fromRGB(26, 28, 34)
	bar.BorderSizePixel = 0
	bar.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = bar

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(220, 70, 70)
	fill.BorderSizePixel = 0
	fill.Parent = bar

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	model.Parent = Workspace:FindFirstChild("MiniBases") or Workspace
	return model
end

local function clearEnemy(run: Run)
	if run.model then
		run.model:Destroy()
		run.model = nil
	end
end

local function showEnemyHealth(run: Run)
	if not run.model then
		return
	end

	local fill = run.model:FindFirstChild("EnemyPlate", true)
	fill = fill and fill:FindFirstChild("HealthBar")
	fill = fill and fill:FindFirstChild("Fill")

	if fill then
		fill.Size = UDim2.fromScale(
			math.clamp(run.enemyHealth / run.enemyMaxHealth, 0, 1),
			1
		)
	end
end

-- The big sign over the pit. Written in the world rather than on the screen, so
-- the player reads their own progress by looking at it -- and reads everyone
-- else's by looking at theirs.
local function updateArenaSign(player: Player, floor: number?)
	local base = MiniBaseService.getBase(player)
	local anchor = base and base:FindFirstChild("ArenaSignAnchor")
	local sign = anchor and anchor:FindFirstChild("ArenaSign")

	if not sign then
		return
	end

	local floorLabel = sign:FindFirstChild("Floor")
	local rewardLabel = sign:FindFirstChild("Reward")

	if floorLabel then
		-- A single big number is the whole point: floor 20 beats floor 10 and a
		-- ten-year-old needs no explanation of why.
		floorLabel.Text = if floor then `FLOOR {floor}` else "COLYSEUM"
	end

	if rewardLabel then
		rewardLabel.Text = if floor
			then `${Format.abbreviate(floorReward(floor))}`
			else ""
	end
end

--[[ Run control ]]

local function startFloor(player: Player, run: Run)
	local fighterSpot, enemySpot =
		MiniBaseService.getPitSpots(player, MiniService.getGrowth(player))

	if not fighterSpot or not enemySpot then
		return
	end

	clearEnemy(run)

	updateArenaSign(player, run.floor)

	run.enemyMaxHealth = enemyHealth(run.floor)
	run.enemyHealth = run.enemyMaxHealth
	run.model = buildEnemy(player, run.floor, enemySpot)

	-- Only the first floor of a run needs the walk across the plot; after that
	-- the Mini is already standing there, so it is just the beat between floors.
	MiniService.enterFighting(
		player,
		fighterSpot,
		if run.epoch then TOWER.FloorBreakSeconds else nil
	)

	local epoch, rate = MiniService.getPunchClock(player, "Fighting")
	run.epoch = epoch

	-- The punch clock now runs unbroken across the whole tower run, so its count
	-- does not restart with the floor. Start this opponent owing nothing for the
	-- punches thrown at the previous one -- otherwise every floor after the
	-- first would take the entire run's punches in its first tick and die on
	-- arrival.
	run.paidPunches = if epoch and rate then PunchClock.landed(epoch, rate) else 0

	run.pausedUntil = 0
end

local function finishRun(player: Player, run: Run, floorsCleared: number)
	run.finished = true
	clearEnemy(run)
	updateArenaSign(player, nil)

	local data = DataService.getData(player)

	if data then
		data.Mini.TowerFloor = TOWER.StartFloor
	end

	MiniService.enterReturning(player)

	AnalyticsService.track(player, "TowerRunEnded", {
		floorsCleared = floorsCleared,
		bestFloor = data and data.Mini.BestFloor or 0,
	})

	if GameConfig.DebugLogging then
		print(`[TowerService] {player.Name} run over after {floorsCleared} floor(s)`)
	end

	-- Walks itself home and gets straight back on the bag. The player never has
	-- to fetch it; the loop closes on its own.
	--
	-- Waits for the Mini to ARRIVE rather than for a stopwatch. The walk home is
	-- the length of the map now, and a fixed delay re-ordered the Mini to the
	-- dojo while it was still on the bridge walking to the dojo -- which sent it
	-- back to the arena to start the journey it was already halfway through.
	task.spawn(function()
		local deadline = os.clock() + WALK_HOME_TIMEOUT

		repeat
			task.wait(0.2)
		until not MiniService.isWalking(player)
			or os.clock() > deadline
			or runs[player] ~= run
			or player.Parent ~= Players

		if runs[player] ~= run or player.Parent ~= Players then
			return
		end

		runs[player] = nil
		MiniService.enterTraining(player)
	end)
end

local function stepRun(player: Player, run: Run, dt: number)
	local data = DataService.getData(player)

	if not data or run.finished then
		return
	end

	local stats = data.Mini
	local now = Workspace:GetServerTimeNow()

	if now < run.pausedUntil then
		return
	end

	local epoch, rate = MiniService.getPunchClock(player, "Fighting")

	if not epoch or not rate then
		return
	end

	-- Nothing happens until the Mini is actually in the pit swinging.
	local landed = PunchClock.landed(epoch, rate)

	if landed <= 0 then
		return
	end

	-- The floor hits back for as long as the fight is live, whether or not the
	-- Mini's own swing has come round yet.
	stats.Health = math.max(0, stats.Health - enemyDamage(run.floor) * dt)

	local unpaid = landed - run.paidPunches

	if unpaid > 0 then
		run.paidPunches = landed
		run.enemyHealth -= unpaid * math.max(1, stats.Power)
		showEnemyHealth(run)
	end

	TrainingService.publish(player, MiniService.get(player))

	if run.enemyHealth <= 0 then
		local reward = floorReward(run.floor)
		data.Currencies.Coins += reward

		if run.floor > stats.BestFloor then
			stats.BestFloor = run.floor
			AnalyticsService.track(player, "TowerBestFloor", { floor = run.floor })
		end

		run.floor += 1
		stats.TowerFloor = run.floor

		clearEnemy(run)
		run.pausedUntil = now + TOWER.FloorBreakSeconds

		-- Rebuild on the next tick so the cleared floor gets its beat of silence.
		task.delay(TOWER.FloorBreakSeconds, function()
			if runs[player] == run and not run.finished then
				startFloor(player, run)
			end
		end)

		TrainingService.publish(player, MiniService.get(player))
		return
	end

	if stats.Health <= 0 then
		stats.Health = 0
		TrainingService.publish(player, MiniService.get(player))

		run.pausedUntil = now + TOWER.KnockoutSeconds

		task.delay(TOWER.KnockoutSeconds, function()
			if runs[player] == run and not run.finished then
				finishRun(player, run, run.floor - TOWER.StartFloor)
			end
		end)
	end
end

--[[ Sending ]]

function TowerService.send(player: Player): boolean
	local data = DataService.getData(player)

	if not data or runs[player] then
		return false
	end

	-- Sending a half-healed Mini is allowed, and is a real decision: fewer
	-- floors now, or more floors after another minute on the bag. The only
	-- thing stopped here is sending one that is already flat out.
	if data.Mini.Health <= 0 then
		return false
	end

	local run: Run = {
		floor = TOWER.StartFloor,
		enemyHealth = 0,
		enemyMaxHealth = 1,
		model = nil,
		paidPunches = 0,
		epoch = nil,
		pausedUntil = 0,
		finished = false,
	}

	runs[player] = run
	data.Mini.TowerFloor = run.floor

	startFloor(player, run)

	AnalyticsService.trackOnce(player, "FirstTowerRun")

	if GameConfig.DebugLogging then
		print(`[TowerService] {player.Name} sent their Mini to the tower`)
	end

	return true
end

-- Pull the Mini out mid-run. It keeps the floors it cleared and the coins they
-- paid; walking away from a fight it was losing is a legitimate call, not a
-- punishable one.
function TowerService.recall(player: Player): boolean
	local run = runs[player]

	if not run then
		return false
	end

	run.finished = true
	clearEnemy(run)
	runs[player] = nil

	local data = DataService.getData(player)

	if data then
		data.Mini.TowerFloor = TOWER.StartFloor
	end

	if GameConfig.DebugLogging then
		print(`[TowerService] {player.Name} called their Mini back`)
	end

	return true
end

function TowerService.isFighting(player: Player): boolean
	return runs[player] ~= nil
end

local function bindPrompt(player: Player, base: Model)
	local post = base:FindFirstChild("TowerPost")
	local prompt = post and post:FindFirstChild("TowerPrompt")

	if not prompt then
		return
	end

	-- ProximityPrompt.Triggered is a server event with a server-side distance
	-- check, so this needs no remote and cannot be fired from a fake client.
	prompt.Triggered:Connect(function(triggeredBy: Player)
		if triggeredBy ~= player then
			return
		end

		TowerService.send(triggeredBy)
	end)
end

function TowerService.Init(registry)
	AnalyticsService = registry.AnalyticsService
	DataService = registry.DataService
	MiniBaseService = registry.MiniBaseService
	MiniService = registry.MiniService
	TrainingService = registry.TrainingService
end

function TowerService.Start()
	MiniBaseService.BaseCreated:Connect(bindPrompt)

	-- Bases built before this service started (players already in the server)
	-- still need their prompt wired up.
	for _, player in Players:GetPlayers() do
		local base = MiniBaseService.getBase(player)

		if base then
			bindPrompt(player, base)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		local run = runs[player]

		if run then
			clearEnemy(run)
			runs[player] = nil
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		for player, run in runs do
			stepRun(player, run, dt)
		end
	end)
end

return TowerService
