--!nonstrict
-- Mini movement presentation.
--
-- The Mini does NOT have a fake procedural walk cycle.
--
-- Its visible body pose is mirrored directly from the owner's real Roblox
-- character every frame. Run, idle, jump, emotes and custom avatar animations
-- therefore naturally flow through to the Mini.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

local SETTINGS = MiniConfig.Personality

local MiniController = {}


type MiniState = {
model: Model,
owner: Player,

position: Vector3,
velocity: Vector3,
forward: Vector3,
groundOffset: number,

sourceCharacter: Model?,
sourceJoints: { [string]: any },
targetJoints: { [string]: any },

reportedJointCount: boolean,
}


local minisFolder: Folder
local states: { [Model]: MiniState } = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType =
Enum.RaycastFilterType.Exclude

raycastParams.IgnoreWater = true


local function horizontal(vector: Vector3): Vector3
return Vector3.new(
vector.X,
0,
vector.Z
)
end


local function safeUnit(
vector: Vector3,
fallback: Vector3
): Vector3

local flat = horizontal(vector)

if flat.Magnitude < 0.001 then
return fallback
end

return flat.Unit
end


local function expAlpha(
response: number,
dt: number
): number

return 1 - math.exp(-response * dt)
end


local function moveTowards(
current: Vector3,
target: Vector3,
maxDelta: number
): Vector3

local delta = target - current
local distance = delta.Magnitude

if distance <= maxDelta
or distance < 0.0001
then
return target
end

return current + delta.Unit * maxDelta
end


-- ============================================================
-- JOINT MIRRORING
--
-- Supports BOTH Roblox joint generations:
--
-- legacy Motor6D
-- modern AnimationConstraint
-- ============================================================

local function isPoseJoint(
instance: Instance
): boolean

return instance:IsA("Motor6D")
or instance:IsA("AnimationConstraint")
end


local function jointKey(
joint: Instance
): string?

if joint:IsA("Motor6D") then
local part0 = joint.Part0
local part1 = joint.Part1

if not part0 or not part1 then
return nil
end

return part0.Name .. ">" .. part1.Name
end


if joint:IsA("AnimationConstraint") then
local attachment0 = joint.Attachment0
local attachment1 = joint.Attachment1

if not attachment0
or not attachment1
or not attachment0.Parent
or not attachment1.Parent
then
return nil
end

return attachment0.Parent.Name
.. ">"
.. attachment1.Parent.Name
end


return nil
end


local function collectPoseJoints(
model: Model
): { [string]: any }

local result = {}

for _, descendant in model:GetDescendants() do
if not isPoseJoint(descendant) then
continue
end

local key = jointKey(descendant)

if key then
result[key] = descendant
end
end

return result
end


local function readTransform(
joint: Instance
): CFrame

if joint:IsA("Motor6D") then
return joint.Transform
end

if joint:IsA("AnimationConstraint") then
return joint.Transform
end

return CFrame.identity
end


local function writeTransform(
joint: Instance,
transform: CFrame
)
if joint:IsA("Motor6D") then
joint.Transform = transform
return
end

if joint:IsA("AnimationConstraint") then
joint.Transform = transform
end
end


local function rebuildSourceJoints(
state: MiniState,
character: Model
)
state.sourceCharacter = character
state.sourceJoints =
collectPoseJoints(character)

state.reportedJointCount = false
end


local function mirrorPose(state: MiniState)
local character =
state.owner.Character

if not character then
return
end

if state.sourceCharacter ~= character then
rebuildSourceJoints(
state,
character
)
end


local matched = 0

for key, sourceJoint in state.sourceJoints do
local targetJoint =
state.targetJoints[key]

if targetJoint then
writeTransform(
targetJoint,
readTransform(sourceJoint)
)

matched += 1
end
end


if GameConfig.DebugLogging
and not state.reportedJointCount
then
state.reportedJointCount = true

print(
`[MiniController] pose mirror {state.owner.Name}: {matched} matching joints`
)
end
end


-- ============================================================
-- ROOT FOLLOW
-- ============================================================

local function calculateGroundOffset(
model: Model
): number

local pivotY =
model:GetPivot().Position.Y

local lowestY = math.huge

for _, descendant in model:GetDescendants() do
if not descendant:IsA("BasePart") then
continue
end

if descendant:FindFirstAncestorOfClass(
"Accessory"
) then
continue
end

local bottom =
descendant.Position.Y
- descendant.Size.Y * 0.5

lowestY =
math.min(
lowestY,
bottom
)
end

if lowestY == math.huge then
return 1
end

return math.max(
0.1,
pivotY - lowestY
)
end


local function ownerFromMini(
model: Model
): Player?

local userId =
model:GetAttribute("OwnerUserId")

if type(userId) ~= "number" then
return nil
end

return Players:GetPlayerByUserId(
userId
)
end


local function register(
instance: Instance
)
if not instance:IsA("Model") then
return
end

task.defer(function()
if not instance.Parent
or states[instance]
then
return
end

local owner =
ownerFromMini(instance)

if not owner then
return
end

local pivot =
instance:GetPivot()

states[instance] = {
model = instance,
owner = owner,

position = pivot.Position,
velocity = Vector3.zero,

forward = safeUnit(
pivot.LookVector,
Vector3.new(0, 0, -1)
),

groundOffset =
calculateGroundOffset(
instance
),

sourceCharacter = nil,
sourceJoints = {},

targetJoints =
collectPoseJoints(
instance
),

reportedJointCount = false,
}

if GameConfig.DebugLogging then
print(
`[MiniController] tracking R15 Mini for {owner.Name}`
)
end
end)
end


local function unregister(
instance: Instance
)
if instance:IsA("Model") then
states[instance] = nil
end
end


local function targetPosition(
state: MiniState,
root: BasePart,
character: Model
): Vector3

local raw =
root.CFrame:PointToWorldSpace(
Vector3.new(
SETTINGS.SideOffsetStuds,
0,
SETTINGS.BackOffsetStuds
)
)

raycastParams.FilterDescendantsInstances = {
character,
minisFolder,
}


local origin =
Vector3.new(
raw.X,
raw.Y
+ SETTINGS.GroundProbeHeightStuds,
raw.Z
)


local hit =
Workspace:Raycast(
origin,

Vector3.new(
0,
-SETTINGS.GroundProbeDistanceStuds,
0
),

raycastParams
)


if hit then
return Vector3.new(
raw.X,

hit.Position.Y
+ state.groundOffset,

raw.Z
)
end


return Vector3.new(
raw.X,
state.position.Y,
raw.Z
)
end


-- The server publishes what the Mini is doing as attributes on the model.
-- Anything other than Follow means the Mini has somewhere of its own to be, and
-- stops tracking the owner.
local function actionTarget(
state: MiniState
): (Vector3?, Vector3?)

local model = state.model

if model:GetAttribute("ActionState") ~= "Training" then
return nil, nil
end


local spot = model:GetAttribute("ActionCFrame")

if typeof(spot) ~= "CFrame" then
return nil, nil
end


-- The server hands us a point ON the floor, while the Mini is positioned by
-- its pivot. Same convention the ground raycast uses.
return spot.Position
+ Vector3.new(0, state.groundOffset, 0),

spot.LookVector
end


local function updateRoot(
state: MiniState,
dt: number
)
local desired, desiredForward =
actionTarget(state)


if not desired then
-- Follow: track the owner, as before.
local character =
state.owner.Character

if not character then
return
end


local root =
character:FindFirstChild(
"HumanoidRootPart"
)

if not root
or not root:IsA("BasePart")
then
return
end


desired =
targetPosition(
state,
root,
character
)

desiredForward =
safeUnit(
root.CFrame.LookVector,
state.forward
)
end


local flatCurrent =
horizontal(state.position)

local flatDesired =
horizontal(desired)

local difference =
flatDesired - flatCurrent

local distance =
difference.Magnitude


if distance
>= MiniConfig.TeleportDistanceStuds
then
state.position = desired
state.velocity = Vector3.zero

else
local desiredVelocity =
Vector3.zero


if distance
> SETTINGS.StopRadiusStuds
then
local direction =
difference.Unit


local arrival =
math.clamp(
(
distance
- SETTINGS.StopRadiusStuds
)
/ SETTINGS.ArrivalRadiusStuds,

0,
1
)


arrival =
arrival
* arrival
* (3 - 2 * arrival)


local catchMultiplier = 1


if distance
> SETTINGS.CatchUpStartStuds
then
catchMultiplier =
math.clamp(
distance
/ SETTINGS.CatchUpStartStuds,

1,
SETTINGS.MaxSpeedMultiplier
)
end


desiredVelocity =
direction
* MiniConfig.MoveSpeed
* arrival
* catchMultiplier
end


local acceleration =
if desiredVelocity.Magnitude
> state.velocity.Magnitude
then
SETTINGS.AccelerationStudsPerSecond2
else
SETTINGS.DecelerationStudsPerSecond2


state.velocity =
moveTowards(
state.velocity,
desiredVelocity,
acceleration * dt
)


local travel =
state.velocity * dt


if distance > 0
and travel.Magnitude > distance
then
state.position =
Vector3.new(
desired.X,
state.position.Y,
desired.Z
)

state.velocity =
Vector3.zero

else
state.position += travel
end


local yAlpha =
expAlpha(
SETTINGS.VerticalResponsiveness,
dt
)


state.position =
Vector3.new(
state.position.X,

state.position.Y
+ (
desired.Y
- state.position.Y
)
* yAlpha,

state.position.Z
)
end


-- Facing comes from the REAL avatar when following, or from the action spot
-- when training. No fake wobble, lean, bob or procedural turning either way.
desiredForward =
safeUnit(
desiredForward or state.forward,
state.forward
)


state.forward =
safeUnit(
state.forward:Lerp(
desiredForward,

expAlpha(
SETTINGS.TurnResponsiveness,
dt
)
),

state.forward
)


local pivot =
CFrame.lookAt(
state.position,
state.position + state.forward
)


state.model:PivotTo(pivot)
end


function MiniController.Init()
minisFolder =
Workspace:WaitForChild("Minis")


for _, child in minisFolder:GetChildren() do
register(child)
end


minisFolder.ChildAdded:Connect(register)
minisFolder.ChildRemoved:Connect(unregister)
end


function MiniController.Start()

-- Roblox Animator has already written the player's pose when
-- PreSimulation fires, so copy it here.
RunService.PreSimulation:Connect(function()
for _, state in states do
mirrorPose(state)
end
end)


RunService.PreRender:Connect(function(dt)
for _, state in states do
updateRoot(
state,
dt
)
end
end)

end


return MiniController