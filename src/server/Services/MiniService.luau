--!nonstrict
-- Runtime owner for every player's visible Mini.
--
-- V0.2 goal:
--   Character appears -> Mini appears immediately -> real avatar look swaps in.
--
-- Movement/personality deliberately comes later. This service only proves the
-- most important product promise: "that tiny fighter is ME."

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

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
local action = actions[player]

if action and action.cframe and action.state ~= "Follow" then
return action.cframe.Position
end

local character = player.Character
local root = character and character:FindFirstChild("HumanoidRootPart")

return root and root.Position or nil
end

-- How long the Mini needs before the first punch can land. Measured rather than
-- assumed, so calling it back from across the plot and then sending it to train
-- does not have it shadow-boxing on the way.
local function walkSecondsTo(player: Player, destination: CFrame): number
local from = currentAnchor(player)

if not from then
return MiniConfig.Training.WalkInSeconds
end

local distance = (destination.Position - from).Magnitude
local travel = distance / MiniConfig.Wander.TravelSpeedStuds

-- A beat on top for turning and settling onto the mark.
return math.clamp(travel + 0.4, 0.6, 12)
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
epoch = Workspace:GetServerTimeNow() + walkSecondsTo(player, spot),
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
local delay = settleSeconds or walkSecondsTo(player, spot)

actions[player] = {
state = "Fighting",
cframe = spot,
rate = MiniConfig.BaseStats.AttacksPerSecond,
epoch = Workspace:GetServerTimeNow() + delay,
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