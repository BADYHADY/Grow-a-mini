--!nonstrict
-- Client-side visual locomotion and personality for Minis.
--
-- Server owns the Mini and gameplay state.
-- This controller only decides how the companion LOOKS while following.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

local SETTINGS = MiniConfig.Personality

local MiniController = {}

type MotorSet = {
LeftShoulder: Motor6D?,
RightShoulder: Motor6D?,
LeftHip: Motor6D?,
RightHip: Motor6D?,
Neck: Motor6D?,
}

type MiniState = {
model: Model,
owner: Player,

position: Vector3,
velocity: Vector3,
forward: Vector3,

groundOffset: number,

gaitPhase: number,
gaitBlend: number,

phaseOffset: number,
motors: MotorSet,
}

local minisFolder: Folder
local states: { [Model]: MiniState } = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true


local function horizontal(vector: Vector3): Vector3
return Vector3.new(vector.X, 0, vector.Z)
end


local function safeUnit(vector: Vector3, fallback: Vector3): Vector3
local flat = horizontal(vector)

if flat.Magnitude < 0.001 then
return fallback
end

return flat.Unit
end


local function moveTowards(
current: Vector3,
target: Vector3,
maxDelta: number
): Vector3
local delta = target - current
local distance = delta.Magnitude

if distance <= maxDelta or distance < 0.0001 then
return target
end

return current + delta.Unit * maxDelta
end


local function expAlpha(response: number, dt: number): number
return 1 - math.exp(-response * dt)
end


local function findMotor(model: Model, name: string): Motor6D?
for _, descendant in model:GetDescendants() do
if descendant:IsA("Motor6D") and descendant.Name == name then
return descendant
end
end

return nil
end


local function collectMotors(model: Model): MotorSet
return {
LeftShoulder = findMotor(model, "Left Shoulder"),
RightShoulder = findMotor(model, "Right Shoulder"),
LeftHip = findMotor(model, "Left Hip"),
RightHip = findMotor(model, "Right Hip"),
Neck = findMotor(model, "Neck"),
}
end


local function calculateGroundOffset(model: Model): number
local pivotY = model:GetPivot().Position.Y
local lowestY = math.huge

for _, descendant in model:GetDescendants() do
if not descendant:IsA("BasePart") then
continue
end

-- Hair/hat size must not affect where the Mini's feet touch ground.
if descendant:FindFirstAncestorOfClass("Accessory") then
continue
end

local bottom =
descendant.Position.Y
- descendant.Size.Y * 0.5

lowestY = math.min(lowestY, bottom)
end

if lowestY == math.huge then
return 1
end

return math.max(0.1, pivotY - lowestY)
end


local function ownerFromMini(model: Model): Player?
local userId = model:GetAttribute("OwnerUserId")

if type(userId) ~= "number" then
return nil
end

return Players:GetPlayerByUserId(userId)
end


local function register(instance: Instance)
if not instance:IsA("Model") then
return
end

task.defer(function()
if not instance.Parent or states[instance] then
return
end

local owner = ownerFromMini(instance)

if not owner then
return
end

local pivot = instance:GetPivot()

states[instance] = {
model = instance,
owner = owner,

position = pivot.Position,
velocity = Vector3.zero,

forward = safeUnit(
pivot.LookVector,
Vector3.new(0, 0, -1)
),

groundOffset = calculateGroundOffset(instance),

gaitPhase = 0,
gaitBlend = 0,

phaseOffset = (owner.UserId % 1000) * 0.037,

motors = collectMotors(instance),
}

if GameConfig.DebugLogging then
print(
`[MiniController] tracking Mini for {owner.Name}`
)
end
end)
end


local function unregister(instance: Instance)
if instance:IsA("Model") then
states[instance] = nil
end
end


local function getDesiredPosition(
state: MiniState,
root: BasePart,
character: Model
): Vector3

local rawTarget =
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

local rayOrigin = Vector3.new(
rawTarget.X,
rawTarget.Y + SETTINGS.GroundProbeHeightStuds,
rawTarget.Z
)

local hit = Workspace:Raycast(
rayOrigin,
Vector3.new(
0,
-SETTINGS.GroundProbeDistanceStuds,
0
),
raycastParams
)

if hit then
return Vector3.new(
rawTarget.X,
hit.Position.Y + state.groundOffset,
rawTarget.Z
)
end

local humanoid =
character:FindFirstChildOfClass("Humanoid")

local floorY =
root.Position.Y
- root.Size.Y * 0.5
- (humanoid and humanoid.HipHeight or 2)

return Vector3.new(
rawTarget.X,
floorY + state.groundOffset,
rawTarget.Z
)
end


local function animateRun(
state: MiniState,
speed: number,
dt: number
)
local motors = state.motors

local moving =
speed > 0.65

local desiredBlend =
if moving then 1 else 0

state.gaitBlend +=
(desiredBlend - state.gaitBlend)
* expAlpha(10, dt)

-- The gait advances from DISTANCE travelled.
-- If speed doubles, foot cadence naturally increases too.
state.gaitPhase +=
speed
* SETTINGS.GaitRadiansPerStud
* dt

local stride =
math.sin(state.gaitPhase)

local blend = state.gaitBlend

local armSwing =
math.rad(SETTINGS.WalkSwingDegrees)
* stride
* blend

local legSwing =
armSwing * 0.85

local idleArm =
math.rad(SETTINGS.IdleArmDegrees)
* (1 - blend)

if motors.RightShoulder then
motors.RightShoulder.Transform =
CFrame.Angles(
armSwing,
0,
idleArm
)
end

if motors.LeftShoulder then
motors.LeftShoulder.Transform =
CFrame.Angles(
-armSwing,
0,
-idleArm
)
end

-- Arms and opposite legs move together like a real run.
if motors.RightHip then
motors.RightHip.Transform =
CFrame.Angles(
-legSwing,
0,
0
)
end

if motors.LeftHip then
motors.LeftHip.Transform =
CFrame.Angles(
legSwing,
0,
0
)
end

if motors.Neck then
local tinyIdleNod =
math.sin(
os.clock() * SETTINGS.IdleBobFrequency
+ state.phaseOffset
)
* math.rad(1)
* (1 - blend)

motors.Neck.Transform =
CFrame.Angles(
tinyIdleNod,
0,
0
)
end
end


local function updateMini(
state: MiniState,
dt: number
)
local model = state.model
local owner = state.owner

if not model.Parent or owner.Parent ~= Players then
states[model] = nil
return
end

local character = owner.Character

if not character then
return
end

local root =
character:FindFirstChild("HumanoidRootPart")

if not root or not root:IsA("BasePart") then
return
end

local desired =
getDesiredPosition(
state,
root,
character
)

local flatPosition =
Vector3.new(
state.position.X,
0,
state.position.Z
)

local flatDesired =
Vector3.new(
desired.X,
0,
desired.Z
)

local toTarget =
flatDesired - flatPosition

local distance =
toTarget.Magnitude


-- Emergency recovery only.
if distance >= MiniConfig.TeleportDistanceStuds then
state.position = desired
state.velocity = Vector3.zero

model:PivotTo(
CFrame.lookAt(
desired,
desired + state.forward
)
)

return
end


-- --------------------------------------------------------
-- ARRIVAL BEHAVIOUR
--
-- Old version:
-- snap toward an exact target at full speed.
--
-- New:
-- accelerate, cruise, then naturally brake into position.
-- --------------------------------------------------------

local desiredVelocity =
Vector3.zero

if distance > SETTINGS.StopRadiusStuds then
local direction =
toTarget.Unit

local arrivalFactor =
math.clamp(
(
distance
- SETTINGS.StopRadiusStuds
)
/ SETTINGS.ArrivalRadiusStuds,
0,
1
)

-- Smoothstep instead of a linear throttle.
arrivalFactor =
arrivalFactor
* arrivalFactor
* (3 - 2 * arrivalFactor)

local catchMultiplier = 1

if distance > SETTINGS.CatchUpStartStuds then
local extra =
(
distance
- SETTINGS.CatchUpStartStuds
)
/ SETTINGS.CatchUpStartStuds

catchMultiplier =
math.clamp(
1 + extra,
1,
SETTINGS.MaxSpeedMultiplier
)
end

local desiredSpeed =
MiniConfig.MoveSpeed
* arrivalFactor
* catchMultiplier

desiredVelocity =
direction * desiredSpeed
end


local horizontalVelocity =
horizontal(state.velocity)

local accelerating =
desiredVelocity.Magnitude
> horizontalVelocity.Magnitude

local acceleration =
if accelerating
then SETTINGS.AccelerationStudsPerSecond2
else SETTINGS.DecelerationStudsPerSecond2

horizontalVelocity =
moveTowards(
horizontalVelocity,
desiredVelocity,
acceleration * dt
)

state.velocity =
horizontalVelocity


-- Prevent a high-speed Mini from overshooting its follow point.
local travel =
horizontalVelocity * dt

if travel.Magnitude > distance and distance > 0 then
flatPosition =
flatDesired

state.velocity =
Vector3.zero
else
flatPosition += travel
end


-- Ground height is smoothed separately.
local yAlpha =
expAlpha(
SETTINGS.VerticalResponsiveness,
dt
)

local newY =
state.position.Y
+ (
desired.Y - state.position.Y
) * yAlpha

state.position =
Vector3.new(
flatPosition.X,
newY,
flatPosition.Z
)


local speed =
horizontal(state.velocity).Magnitude


-- --------------------------------------------------------
-- FACING
-- --------------------------------------------------------

local desiredForward

if speed > 0.5 then
desiredForward =
safeUnit(
state.velocity,
state.forward
)
else
-- At rest Mini looks toward its owner.
desiredForward =
safeUnit(
root.Position - state.position,
state.forward
)
end

local turnAlpha =
expAlpha(
SETTINGS.TurnResponsiveness,
dt
)

state.forward =
safeUnit(
state.forward:Lerp(
desiredForward,
turnAlpha
),
state.forward
)


-- --------------------------------------------------------
-- GAIT
-- --------------------------------------------------------

animateRun(
state,
speed,
dt
)


-- Mini no longer oscillates through the floor.
-- The run bounce only lifts the body UP during a stride.
local speedRatio =
math.clamp(
speed / MiniConfig.MoveSpeed,
0,
1.4
)

local runBob =
math.abs(
math.sin(state.gaitPhase)
)
* SETTINGS.MoveBobHeight
* state.gaitBlend
* math.min(speedRatio, 1)

local idleBob =
math.sin(
os.clock() * SETTINGS.IdleBobFrequency
+ state.phaseOffset
)
* SETTINGS.IdleBobHeight
* (1 - state.gaitBlend)


local renderPosition =
state.position
+ Vector3.new(
0,
runBob + idleBob,
0
)


local facing =
CFrame.lookAt(
renderPosition,
renderPosition + state.forward
)


-- Constant FORWARD running lean.
-- The previous version rolled left/right every stride which read as waddling.
local forwardLean =
-math.rad(
SETTINGS.LeanDegrees
)
* math.clamp(
speedRatio,
0,
1
)
* state.gaitBlend


model:PivotTo(
facing
* CFrame.Angles(
forwardLean,
0,
0
)
)
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
RunService:BindToRenderStep(
"MiniPersonality",
Enum.RenderPriority.Character.Value + 1,

function(dt)
for _, state in states do
updateMini(state, dt)
end
end
)
end


function MiniController.Destroy()
RunService:UnbindFromRenderStep(
"MiniPersonality"
)

table.clear(states)
end


return MiniController