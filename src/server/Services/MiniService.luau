--!nonstrict
-- Runtime owner for every player's visible Mini.
--
-- V0.2 goal:
--   Character appears -> Mini appears immediately -> real avatar look swaps in.
--
-- Movement/personality deliberately comes later. This service only proves the
-- most important product promise: "that tiny fighter is ME."

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)
local PathAgent = require(Shared.Util.PathAgent)

-- How long the Mini stays beside its owner before walking off to train.
-- Long enough for the "that tiny fighter is ME" beat to land, short enough that
-- the player is not left waiting for something to happen.
local TRAINING_ENTRY_DELAY = 2.0

local MiniService = {}

local AnalyticsService
local MiniAvatarService
local MiniBaseService

local minisFolder: Folder
local blankTemplate: Model

local minis: { [Player]: Model } = {}
local generations: { [Player]: number } = {}

-- How much bigger than base scale each player's Mini currently is. Kept here
-- rather than read off the model, because the model is REPLACED when the real
-- avatar appearance swaps in and the replacement starts at base scale.
local growths: { [Player]: number } = {}

-- What the Mini is currently doing, per player. Held here rather than on the
-- model because the model is REPLACED when the real avatar appearance swaps in,
-- and the action has to survive that swap.
local actions: {
[Player]: {
state: string,
cframe: CFrame?,
rate: number?,
epoch: number?,
},
} = {}

--[[ Walking ]]
--
-- The Mini is moved by the ENGINE, not by us. Humanoid:MoveTo walks it, the
-- Humanoid state machine picks up running and landing, and the Animator plays
-- the walk cycle -- all of which Roblox does better than a hand-written
-- simulation, and all of which is why the Mini used to slide rather than walk.
--
-- The server drives it because where the Mini is IS part of what it is doing.
-- The client no longer guesses.

-- Waypoints are corners to round, not marks to hit. Shared with the path agent
-- so "already heading there" and "arrived" agree on what close enough means.
local WALK_ARRIVE_RADIUS = 1.2

-- The route is published as numbered attributes because attributes cannot hold
-- a table, and this replicates to every client for free -- the same reason the
-- rest of the action is published this way.
local function publishRoute(mini: Model, points: { Vector3 }?)
	local previous = mini:GetAttribute("RouteCount") or 0

	for index = 1, math.max(previous, points and #points or 0) do
		mini:SetAttribute(`RoutePoint{index}`, points and points[index] or nil)
	end

	mini:SetAttribute("RouteCount", points and #points or nil)
end

local function humanoidOf(mini: Model?): Humanoid?
	return mini and mini:FindFirstChildOfClass("Humanoid") or nil
end

-- One walking agent per Mini, rebuilt whenever the model is replaced by the
-- real-appearance swap.
local agents: { [Player]: any } = {}

-- Where the walk currently under way is headed, so a fresh order for the SAME
-- place does not restart it. The tower issues a new Fighting action for every
-- floor, and restarting each time left the Mini fighting the run from its dojo.
local walkDestinations: { [Player]: Vector3? } = {}

local function agentFor(player: Player, mini: Model): any?
	local humanoid = humanoidOf(mini)

	if not humanoid then
		return nil
	end

	local existing = agents[player]

	if existing and existing.humanoid == humanoid then
		return existing
	end

	if existing then
		existing:cancel()
	end

	local growth = MiniService.getGrowth(player)

	-- Sized as the two-stud fighter it is. Given a player's dimensions instead,
	-- PathfindingService reports NoPath through gaps the Mini walks easily.
	local agent = PathAgent.new(humanoid, {
		AgentRadius = 0.5 * growth,
		AgentHeight = 2.0 * growth,
		AgentCanJump = false,
		AgentCanClimb = false,

		-- The ground under the map is walkable as far as the engine is
		-- concerned, so the Mini used to cut straight across it instead of
		-- taking the bridge. Anything wearing the OffMap PathfindingModifier is
		-- priced out of every route: infinite cost is the documented way to
		-- make a region impassable without making it non-solid.
		Costs = {
			OffMap = math.huge,
		},
	}, WALK_ARRIVE_RADIUS)

	agents[player] = agent

	return agent
end

-- Send the Mini somewhere and let the agent get it there. Publishes the route it
-- chose so every client can see the same journey.
local function driveTo(player: Player, mini: Model, destination: Vector3?, facing: CFrame?)
	local agent = agentFor(player, mini)

	if not agent then
		return
	end

	if not destination then
		agent:cancel()
		walkDestinations[player] = nil
		publishRoute(mini, nil)
		return
	end

	walkDestinations[player] = destination

	task.spawn(function()
		agent:walkTo(destination, function(points)
			publishRoute(mini, points)
		end)

		if walkDestinations[player] ~= destination then
			return
		end

		publishRoute(mini, nil)

		-- Square up on arrival. A fighter facing the wrong way punches past the
		-- bag it was sent to hit.
		if facing and mini.PrimaryPart and not agent:isWalking() then
			local root = mini.PrimaryPart
			root.CFrame = CFrame.lookAt(
				root.Position,
				root.Position + facing.LookVector
			)
		end
	end)
end

-- The action is published as attributes. Attributes replicate on their own, so
-- every client -- not just the owner -- sees the same Mini doing the same
-- thing, and no remote is needed.
local function applyAction(player: Player, mini: Model?)
	local action = actions[player]
	if not action or not mini then
		return
	end

	-- Written on every change, INCLUDING to nil. A stale punch epoch left over
	-- from the last state is how a Mini ends up shadow-boxing in a corner.
	mini:SetAttribute("ActionCFrame", action.cframe)
	mini:SetAttribute("PunchEpoch", action.epoch)

	-- The punch RHYTHM is server-owned even though the punch ANIMATION is not.
	-- Publishing the rate instead of each individual swing keeps the wire quiet
	-- with twenty-four Minis training at once, and leaves one number to change
	-- when upgrades start touching attack speed.
	-- Both sides count punches as `floor((serverTime - epoch) * rate)`. Sharing
	-- the clock instead of the events means the Power above the Mini's head can
	-- never disagree with the fists on screen, however long the session runs.
	mini:SetAttribute("AttackRate", action.rate)

	-- Set last: the client reads the others when this changes.
	mini:SetAttribute("ActionState", action.state)

	-- And actually go. Issued on every action change, which is what makes a
	-- command take effect the instant it is pressed: the walk in progress is
	-- superseded rather than allowed to finish.
	if action.state == "Follow" then
		-- Following tracks a moving target, so it is stepped continuously
		-- rather than walked once. Cancel whatever journey was under way.
		driveTo(player, mini, nil)
		return
	end

	local spot = action.cframe

	-- If a walk to the SAME place is already under way, it is still the right
	-- walk -- leave it running. This is the between-floors case: the tower
	-- re-issues Fighting for every floor, and restarting the journey each time
	-- left the Mini fighting the whole run from inside its own dojo.
	local heading = walkDestinations[player]

	if spot and heading and (heading - spot.Position).Magnitude < WALK_ARRIVE_RADIUS then
		return
	end

	driveTo(player, mini, spot and spot.Position or nil, spot)
end

-- Growth is applied to the model rather than baked into the avatar build, so a
-- Mini that levels up can grow in place without being rebuilt.
local function scaleMini(mini: Model, growth: number)
mini:ScaleTo(MiniConfig.Scale.Overall * growth)
mini:SetAttribute("Growth", growth)
end

local function nextGeneration(player: Player): number
local generation = (generations[player] or 0) + 1
generations[player] = generation
return generation
end

local function isCurrent(player: Player, generation: number): boolean
return player.Parent == Players and generations[player] == generation
end

local function destroyMini(player: Player)
local mini = minis[player]
if mini then
minis[player] = nil
mini:Destroy()
end
end

local function placeBesideCharacter(character: Model, mini: Model)
local root = character:FindFirstChild("HumanoidRootPart")

if not root then
root = character:WaitForChild("HumanoidRootPart", 5)
end

if not root or not root:IsA("BasePart") then
return
end

local humanoid = character:FindFirstChildOfClass("Humanoid")

-- Slightly forward and to the player's right so the Mini is immediately
-- visible without spawning underneath the player's feet.
local offset = root.CFrame * CFrame.new(3.2, 0, 2.0)

local facing = CFrame.lookAt(
offset.Position,
offset.Position + root.CFrame.LookVector
)

mini:PivotTo(facing)

-- Put the Mini's feet on approximately the same ground plane as the player.
local characterFloorY =
root.Position.Y
- root.Size.Y * 0.5
- (humanoid and humanoid.HipHeight or 2)

local boxCFrame, boxSize = mini:GetBoundingBox()
local miniFloorY = boxCFrame.Position.Y - boxSize.Y * 0.5

local deltaY = characterFloorY - miniFloorY

mini:PivotTo(
CFrame.new(0, deltaY, 0) * mini:GetPivot()
)
end

-- Unanchored parts standing next to a player are handed to that player's client
-- automatically, and our client no longer simulates the Mini at all -- so the
-- server would push the body and have the change immediately overwritten by a
-- client reporting that nothing moved. Claiming ownership is what makes
-- Humanoid:MoveTo actually move anything.
local function claimPhysics(mini: Model)
	local root = mini.PrimaryPart

	if not root or root.Anchored then
		return
	end

	local ok, err = pcall(root.SetNetworkOwner, root, nil)

	if not ok then
		warn(`[MiniService] could not claim physics ownership: {err}`)
	end
end

local function loadAppearance(
player: Player,
character: Model,
generation: number
)
local timeoutSeconds = MiniConfig.Appearance.FetchTimeoutSeconds
local startedAt = os.clock()

-- The Roblox avatar request itself cannot be cancelled once yielding.
-- The important contract is that gameplay never waits for it. The grey Mini
-- already exists; after this deadline a late result is simply discarded.
task.delay(timeoutSeconds, function()
if not isCurrent(player, generation) then
return
end

local current = minis[player]
if current and current:GetAttribute("AppearanceReady") ~= true then
AnalyticsService.track(
player,
"MiniAppearanceTimeout",
{ timeoutSeconds = timeoutSeconds }
)

if GameConfig.DebugLogging then
warn(
`[MiniService] avatar appearance timed out for {player.Name}`
)
end
end
end)

local realMini = MiniAvatarService.buildAsync(player.UserId)
local elapsed = os.clock() - startedAt

if not isCurrent(player, generation) then
realMini:Destroy()
return
end

-- A result that arrived after the product deadline must not suddenly pop in
-- much later while the player is already doing something else.
if elapsed > timeoutSeconds then
realMini:Destroy()
return
end

-- MiniAvatarService returns Mini_Blank when Roblox's appearance service
-- fails. We already have a correctly-positioned placeholder, so keep it.
if realMini.Name == "Mini_Blank" then
realMini:Destroy()

AnalyticsService.track(
player,
"MiniAppearanceFallback",
{ loadMs = math.round(elapsed * 1000) }
)

return
end

local current = minis[player]
if not current then
realMini:Destroy()
return
end

realMini.Name = `Mini_{player.UserId}`
realMini:SetAttribute("OwnerUserId", player.UserId)
realMini:SetAttribute("AppearanceReady", true)

-- The replacement is built at base scale and has to inherit whatever the
-- placeholder had grown to.
scaleMini(realMini, MiniService.getGrowth(player))

-- Preserve the exact placeholder position for a visually clean swap.
realMini:PivotTo(current:GetPivot())
realMini.Parent = minisFolder
claimPhysics(realMini)

current:Destroy()
minis[player] = realMini

-- The placeholder carried the action attributes; its replacement has to
-- inherit them or the Mini silently reverts to following.
applyAction(player, realMini)

AnalyticsService.trackOnce(
player,
"MiniAppearanceApplied",
{ loadMs = math.round(elapsed * 1000) }
)

if GameConfig.DebugLogging then
print(
`[MiniService] {player.Name} appearance ready in {math.round(elapsed * 1000)} ms`
)
end
end

local function spawnForCharacter(player: Player, character: Model)
local generation = nextGeneration(player)

destroyMini(player)

AnalyticsService.trackOnce(player, "CharacterLoaded")

-- Instant local clone: zero avatar-network dependency on the spawn path.
local mini = blankTemplate:Clone()

mini.Name = `Mini_{player.UserId}`
mini:SetAttribute("OwnerUserId", player.UserId)
mini:SetAttribute("AppearanceReady", false)

-- A returning player's Mini is already grown, and must not pop back to
-- beginner size for the second it takes the real appearance to land.
scaleMini(mini, MiniService.getGrowth(player))

mini.Parent = minisFolder
claimPhysics(mini)

placeBesideCharacter(character, mini)

minis[player] = mini

-- A fresh character means a fresh Mini, so it starts at the owner's side
-- again rather than inheriting a stale training pose from the last life.
actions[player] = { state = "Follow" }
applyAction(player, mini)

AnalyticsService.trackOnce(player, "MiniGenerated")

-- Fetching and building the recognisable appearance happens entirely away
-- from the player/character spawn path.
task.spawn(loadAppearance, player, character, generation)

-- Then it heads to its dojo and gets to work. The Mini is an automatic
-- fighter -- the player decides WHAT it does, not each individual action.
task.delay(TRAINING_ENTRY_DELAY, function()
if isCurrent(player, generation) then
MiniService.enterTraining(player)
end
end)
end

local function onPlayerAdded(player: Player)
player.CharacterAdded:Connect(function(character)
task.defer(spawnForCharacter, player, character)
end)

if player.Character then
task.defer(spawnForCharacter, player, player.Character)
end
end

--[[ Growth ]]

function MiniService.getGrowth(player: Player): number
return growths[player] or 1
end

-- Everything the Mini reaches for is measured in Mini-lengths, so a Mini that
-- grew has to stand further back from the bag and from its opponent. Recomputed
-- here rather than at each call site, or one of them eventually gets forgotten
-- and a grown fighter punches through the thing it is hitting.
local function spotForState(player: Player, state: string): CFrame?
local growth = MiniService.getGrowth(player)

if state == "Fighting" then
return (MiniBaseService.getPitSpots(player, growth))
end

return MiniBaseService.getTrainingCFrame(player, growth)
end

-- Re-aims the current action without disturbing the punch clock, so growing
-- mid-session does not cost the Mini its rhythm.
local function refreshActionSpot(player: Player)
local action = actions[player]

if not action or action.state == "Follow" then
return
end

local spot = spotForState(player, action.state)

if spot then
action.cframe = spot
applyAction(player, minis[player])
end
end

-- Called when the Mini levels up. The whole point of a level is that you can
-- SEE it happened without reading anything.
function MiniService.applyGrowth(player: Player, level: number)
local growth = math.min(
1 + (level - 1) * MiniConfig.Growth.ScalePerLevel,
MiniConfig.Growth.MaxScaleMultiplier
)

if growths[player] == growth then
return
end

growths[player] = growth

local mini = minis[player]

if mini then
scaleMini(mini, growth)
end

refreshActionSpot(player)
end

--[[ Walking time ]]

-- The client simulates where the Mini actually is, so the server cannot read its
-- position off the model. It does not need to: the last place it TOLD the Mini
-- to go is where the Mini is, and a following Mini is next to its owner.
local function currentAnchor(player: Player): Vector3?
-- The Mini is a physical body the server drives, so its position is simply
-- read off it. This used to reason from the last place the Mini was TOLD to
-- go, because the client owned movement and the server could not know where it
-- had ended up. Planning a route from an imagined position is how the Mini got
-- shoved into the back wall of its own dojo: pathfinding was solving from a
-- point it was not standing on.
local mini = minis[player]

if mini and mini.PrimaryPart then
return mini.PrimaryPart.Position
end

local character = player.Character
local root = character and character:FindFirstChild("HumanoidRootPart")

return root and root.Position or nil
end

-- How long the Mini needs before the first punch can land. Measured rather than
-- assumed, so calling it back from across the plot and then sending it to train
-- does not have it shadow-boxing on the way.
-- The route the Mini walks to get somewhere, as a list of points it can travel
-- between in a straight line. The map is a dojo platform, a bridge and an arena
-- plate strung out over a hundred studs, so a straight line from the bag to the
-- Colyseum goes through open air -- the Mini has to be told to use the bridge.
--
-- Computed on the server because the route is part of what the Mini is DOING,
-- not how it is drawn, and because the walk-in time the punch clock depends on
-- has to be measured against the real distance rather than the crow's flight.
local function routeTo(player: Player, destination: Vector3): { Vector3 }
local from = currentAnchor(player)

if not from then
return { destination }
end

local growth = MiniService.getGrowth(player)
local path = PathfindingService:CreatePath({
-- The agent is a two-stud fighter, not a player. Sizing it as a player
-- makes every gap look impassable and the path falls back to nothing.
AgentRadius = 0.6 * growth,
AgentHeight = 2.2 * growth,
AgentCanJump = false,
})

-- The Colyseum is a closed bowl: its seating ring has no doorway cut into it,
-- so there is no walkable route onto the sand and pathfinding correctly says
-- NoPath. Route to the arena's edge instead and let the Mini cover the last
-- few studs in a straight line, the way it steps up onto anything else. The
-- long walk -- the dojo, the bridge, the plate -- is the part worth pathing.
local approach = MiniBaseService.getArenaApproach(player, destination) or destination

-- The same wall in reverse: a Mini standing on the sand cannot path OUT of
-- the arena either, which is how the walk home used to be a teleport. Start
-- the route at the arena's edge and put that step in front of it.
local exit = MiniBaseService.getArenaApproach(player, from)
local ok = pcall(path.ComputeAsync, path, exit or from, approach)

if not ok or path.Status ~= Enum.PathStatus.Success then
-- No route: walk at it directly rather than refusing to move. A Mini that
-- stands still because the navmesh has not baked is worse than one that
-- takes a shortcut.
return { destination }
end

local points = {}

for index, waypoint in path:GetWaypoints() do
-- The first waypoint is where the Mini already is.
if index > 1 then
table.insert(points, waypoint.Position)
end
end

if #points == 0 then
return { destination }
end

-- Finish on the exact spot the caller asked for. Pathfinding snaps its last
-- waypoint to the navmesh, which is close but not the mark the punch was
-- measured against -- and when the route stopped at the arena's edge, the
-- mark is inside the building the route could not enter.
if approach == destination then
points[#points] = destination
else
table.insert(points, destination)
end

-- Walk out of the building before walking anywhere else.
if exit then
table.insert(points, 1, exit)
end

return points
end

-- How long before the first punch can land: how long the walk there takes.
-- Measured along the real route rather than the crow's flight, because the map
-- is a dojo, a bridge and an arena strung out over a hundred studs and the two
-- differ by a factor of two. Server and client both hang the punch clock off
-- this, so the first fist lands exactly when the fighter arrives.
local function walkSecondsTo(player: Player, destination: Vector3): number
local from = currentAnchor(player)

if not from then
return MiniConfig.Training.WalkInSeconds
end

local distance = 0
local previous = from

for _, point in routeTo(player, destination) do
distance += (point - previous).Magnitude
previous = point
end

local travel = distance / MiniConfig.Wander.TravelSpeedStuds

-- A beat on top for turning and settling onto the mark.
return math.clamp(travel + 0.4, 0.6, 40)
end

--[[ Action state ]]

-- Send the Mini to its dojo to train, and keep it there. The player is free to
-- walk away; the fighter keeps working. That separation -- player decides,
-- Mini executes -- is the loop this whole game is built on.
function MiniService.enterTraining(player: Player): boolean
local spot = spotForState(player, "Training")

if not spot then
warn(`[MiniService] no training spot for {player.Name}; staying in Follow`)
return false
end

actions[player] = {
state = "Training",
cframe = spot,
rate = MiniConfig.BaseStats.AttacksPerSecond,

-- The first punch cannot land until the Mini has walked to the bag.
epoch = Workspace:GetServerTimeNow() + walkSecondsTo(player, spot.Position),
}
applyAction(player, minis[player])

AnalyticsService.trackOnce(player, "FirstTrainingStarted")

if GameConfig.DebugLogging then
print(`[MiniService] {player.Name} Mini entering training`)
end

return true
end

function MiniService.enterFollow(player: Player)
actions[player] = { state = "Follow" }
applyAction(player, minis[player])
end

-- Topped up and off the clock. The Mini mooches around the dojo, which is the
-- only signal the player needs that it is ready to be sent out again.
function MiniService.enterReady(player: Player)
local spot = spotForState(player, "Training")

actions[player] = { state = "Ready", cframe = spot }
applyAction(player, minis[player])

if GameConfig.DebugLogging then
print(`[MiniService] {player.Name} Mini is ready to fight`)
end
end

-- In the pit, throwing punches at whatever the tower put in front of it. Same
-- punch clock as training, so the fists on screen are the hits TowerService
-- resolves.
-- `settleSeconds` is the pause between floors; the walk out to the pit is
-- measured from wherever the Mini currently is.
function MiniService.enterFighting(player: Player, spot: CFrame, settleSeconds: number?)
-- Between floors the Mini is already standing on the mark, so there is no
-- route to walk and no reason to pay for one.
local delay = settleSeconds or walkSecondsTo(player, spot.Position)

-- A fight is faster than a training session. Training is a rhythm the player
-- watches for a minute at a time; a fight is meant to be over. Sharing one
-- rate made floor 1 -- an opponent two punches wide -- take six seconds.
local rate = MiniConfig.Tower.AttackRate

-- Punch ONE lands almost as soon as the Mini is on the mark.
--
-- The clock counts punch N as floor((now - epoch) * rate), so an epoch set to
-- the arrival time means the first hit does not land until a whole punch
-- period later. With the break between floors on top of it, every cleared
-- opponent was followed by two seconds of a Mini standing perfectly still in
-- front of the next one. Backdating the epoch by very nearly one period puts
-- the swing already in progress on arrival, so it connects immediately.
actions[player] = {
state = "Fighting",
cframe = spot,
rate = rate,
epoch = Workspace:GetServerTimeNow() + delay - 1 / rate + MiniConfig.Tower.WindupSeconds,
}
applyAction(player, minis[player])
end

-- Beaten, and walking home to the bag under its own steam. No punch clock: it
-- is not earning anything on the way back.
function MiniService.enterReturning(player: Player)
local spot = spotForState(player, "Training")

actions[player] = { state = "Returning", cframe = spot }
applyAction(player, minis[player])
end

-- True while the Mini is still walking somewhere it was sent. Used instead of a
-- fixed delay by anything that has to happen ON ARRIVAL.
function MiniService.isWalking(player: Player): boolean
local agent = agents[player]
return agent ~= nil and agent:isWalking()
end

function MiniService.getAction(player: Player): string
local action = actions[player]
return action and action.state or "Follow"
end

-- (punchEpoch, punchesPerSecond) while the Mini is throwing punches for a given
-- state, nil otherwise. TrainingService and TowerService pay out against this.
function MiniService.getPunchClock(player: Player, state: string): (number?, number?)
local action = actions[player]

if not action or action.state ~= state then
return nil, nil
end

return action.epoch, action.rate
end

--[[ The two states that have no fixed destination ]]
--
-- Following chases a target that keeps moving, and wandering has no destination
-- at all until it picks one. Both are stepped rather than walked once, so they
-- live here instead of going through the path agent.

-- Where the Mini is loitering next, per player, and until when.
local wanderSpots: { [Player]: { point: Vector3, until_: number } } = {}

local function stepFollow(player: Player, mini: Model, humanoid: Humanoid)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root or not mini.PrimaryPart then
		return
	end

	-- Just behind and to the side, the way a person walks with a dog. Standing
	-- ON the owner reads as a bug; trailing them reads as company.
	local beside = root.CFrame * CFrame.new(
		MiniConfig.Personality.SideOffsetStuds,
		0,
		MiniConfig.Personality.BackOffsetStuds
	)
	local distance = (mini.PrimaryPart.Position - beside.Position).Magnitude

	-- A dead zone, so a Mini standing next to a stationary player does not
	-- twitch back and forth over the exact spot.
	if distance > MiniConfig.FollowDistanceStuds * 0.4 then
		humanoid:MoveTo(beside.Position)
	end
end

local function stepWander(player: Player, mini: Model, humanoid: Humanoid)
	local base = MiniBaseService.getBase(player)
	local centre = base and base:GetAttribute("WanderCenter")
	local extents = base and base:GetAttribute("WanderExtents")

	if typeof(centre) ~= "Vector3" or typeof(extents) ~= "Vector2" then
		return
	end

	local spot = wanderSpots[player]
	local root = mini.PrimaryPart

	if not root then
		return
	end

	local arrived = spot
		and (Vector3.new(root.Position.X, 0, root.Position.Z)
			- Vector3.new(spot.point.X, 0, spot.point.Z)).Magnitude
			< WALK_ARRIVE_RADIUS

	if spot and not arrived then
		humanoid:MoveTo(spot.point)
		return
	end

	-- Standing at the last spot: wait a bit, then pick somewhere else. The
	-- spread in the pause is what stops it looking like it is on a timer.
	if spot and os.clock() < spot.until_ then
		return
	end

	local WANDER = MiniConfig.Wander

	wanderSpots[player] = {
		point = centre + Vector3.new(
			(math.random() * 2 - 1) * extents.X,
			0,
			(math.random() * 2 - 1) * extents.Y
		),
		until_ = os.clock()
			+ WANDER.PauseSecondsMin
			+ math.random() * (WANDER.PauseSecondsMax - WANDER.PauseSecondsMin),
	}
end

local function stepLoiterStates()
	for player, mini in minis do
		local action = actions[player]
		local state = action and action.state

		if state ~= "Follow" and state ~= "Ready" then
			wanderSpots[player] = nil
			continue
		end

		local humanoid = humanoidOf(mini)

		if not humanoid or not mini.Parent then
			continue
		end

		if state == "Follow" then
			wanderSpots[player] = nil
			stepFollow(player, mini, humanoid)
		else
			stepWander(player, mini, humanoid)
		end
	end
end

function MiniService.Init(registry)
AnalyticsService = registry.AnalyticsService
MiniAvatarService = registry.MiniAvatarService
MiniBaseService = registry.MiniBaseService

local existing = Workspace:FindFirstChild("Minis")

if existing and existing:IsA("Folder") then
minisFolder = existing
else
if existing then
existing:Destroy()
end

minisFolder = Instance.new("Folder")
minisFolder.Name = "Minis"
minisFolder.Parent = Workspace
end

-- Building an empty Roblox rig may yield once during server boot, but every
-- actual player spawn clones this already-finished template instantly.
blankTemplate = MiniAvatarService.buildBlank()
blankTemplate.Name = "_BlankMiniTemplate"
end

function MiniService.Start()
Players.PlayerAdded:Connect(onPlayerAdded)

-- Four times a second is plenty to re-aim a walk; MoveTo does the actual
-- steering every frame on its own.
task.spawn(function()
while true do
task.wait(0.25)

local ok, err = pcall(stepLoiterStates)

if not ok then
warn(`[MiniService] loiter step failed: {err}`)
end
end
end)

Players.PlayerRemoving:Connect(function(player)
nextGeneration(player)
destroyMini(player)
generations[player] = nil
actions[player] = nil
growths[player] = nil
end)

for _, player in Players:GetPlayers() do
onPlayerAdded(player)
end
end

function MiniService.get(player: Player): Model?
return minis[player]
end

return MiniService