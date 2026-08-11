--!nonstrict
-- Builds the player's Mini from a real R15 Roblox avatar.
--
-- Product rule:
-- The Mini must still BE the player.
--
-- We deliberately keep the real R15 avatar topology instead of inventing an
-- R6 animation skeleton. This lets the Mini inherit modern avatar appearance
-- and allows the client to mirror the owner's real animated pose.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

local APPEARANCE = MiniConfig.Appearance
local SCALE = MiniConfig.Scale

local MiniAvatarService = {}

type CacheEntry = {
description: HumanoidDescription,
expiresAt: number,
}

local descriptionCache: { [number]: CacheEntry } = {}


local function quietenHumanoid(humanoid: Humanoid)
humanoid.DisplayDistanceType =
Enum.HumanoidDisplayDistanceType.None

humanoid.NameDisplayDistance = 0
humanoid.HealthDisplayDistance = 0

humanoid.EvaluateStateMachine = false
humanoid.RequiresNeck = false
humanoid.BreakJointsOnDeath = false
end


local function makeLightweight(model: Model)
for _, descendant in model:GetDescendants() do
if descendant:IsA("BasePart") then
descendant.CanCollide = false
descendant.CanQuery = false
descendant.CanTouch = false
descendant.Massless = true
descendant.CastShadow = false
end
end
end


local function styleDescription(
description: HumanoidDescription
)
local style = SCALE.R15

-- Preserve the player's actual body and clothes while nudging proportions
-- toward a collectible Mini silhouette.
description.HeadScale =
math.clamp(
description.HeadScale * style.HeadMultiplier,
0.85,
1.35
)

description.HeightScale =
math.clamp(
description.HeightScale * style.HeightMultiplier,
0.75,
1.15
)

description.WidthScale =
math.clamp(
description.WidthScale * style.WidthMultiplier,
0.80,
1.25
)

description.DepthScale =
math.clamp(
description.DepthScale * style.DepthMultiplier,
0.80,
1.25
)
end


function MiniAvatarService.getDescription(
userId: number
): HumanoidDescription?

local cached = descriptionCache[userId]

if cached and os.clock() < cached.expiresAt then
return cached.description
end

local ok, result = pcall(function()
return Players:GetHumanoidDescriptionFromUserIdAsync(
userId
)
end)

if not ok then
warn(
`[MiniAvatarService] avatar fetch failed for {userId}: {result}`
)

return nil
end

descriptionCache[userId] = {
description = result,
expiresAt = os.clock() + APPEARANCE.CacheSeconds,
}

return result
end


function MiniAvatarService.finalise(model: Model)
-- ScaleTo keeps the standard rig intact rather than manually rebuilding
-- joints. That is essential for pose mirroring.
model:ScaleTo(SCALE.Overall)

makeLightweight(model)

local humanoid =
model:FindFirstChildOfClass("Humanoid")

if humanoid then
quietenHumanoid(humanoid)
end

local root =
model:FindFirstChild("HumanoidRootPart")

if root and root:IsA("BasePart") then
model.PrimaryPart = root
root.Anchored = true
end
end


function MiniAvatarService.buildBlank(): Model
local description =
Instance.new("HumanoidDescription")

styleDescription(description)

local model =
Players:CreateHumanoidModelFromDescriptionAsync(
description,
Enum.HumanoidRigType.R15
)

model.Name = "Mini_Blank"

for _, descendant in model:GetDescendants() do
if descendant:IsA("BasePart") then
descendant.Color =
Color3.fromRGB(156, 156, 156)
end
end

MiniAvatarService.finalise(model)

return model
end


function MiniAvatarService.buildAsync(
userId: number
): Model

local description =
MiniAvatarService.getDescription(userId)

if not description then
return MiniAvatarService.buildBlank()
end

local miniDescription =
description:Clone()

-- IMPORTANT:
-- Do NOT strip layered clothing or normal accessories here.
-- Identity beats premature optimization.
styleDescription(miniDescription)

local ok, model = pcall(function()
return Players:CreateHumanoidModelFromDescriptionAsync(
miniDescription,
Enum.HumanoidRigType.R15
)
end)

miniDescription:Destroy()

if not ok or not model then
warn(
`[MiniAvatarService] R15 rig build failed for {userId}: {model}`
)

return MiniAvatarService.buildBlank()
end

model.Name = `Mini_{userId}`

MiniAvatarService.finalise(model)

return model
end


function MiniAvatarService.Init()
Players.PlayerRemoving:Connect(function(player)
descriptionCache[player.UserId] = nil
end)
end


return MiniAvatarService