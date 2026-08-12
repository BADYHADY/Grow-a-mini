--!nonstrict
-- Builds the player's Mini from a real R15 Roblox avatar.
--
-- Product rule:
-- The Mini must still BE the player.
--
-- We deliberately keep the real R15 avatar topology instead of inventing an
-- R6 animation skeleton. This lets the Mini inherit modern avatar appearance
-- and allows the client to mirror the owner's real animated pose.

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

local APPEARANCE = MiniConfig.Appearance
local SCALE = MiniConfig.Scale

local MiniAvatarService = {}

-- Named here rather than in config: these are physics plumbing, not tuning.
MiniAvatarService.CollisionGroup = "Minis"
local PLAYER_COLLISION_GROUP = "Players"

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

-- The state machine is what MAKES a Humanoid walk: running, landing, falling,
-- and the animations that go with each. We used to switch it off and move the
-- rig by hand, which is exactly why the Mini slid around instead of walking.
humanoid.EvaluateStateMachine = true
humanoid.RequiresNeck = false
humanoid.BreakJointsOnDeath = false

-- A two-stud fighter needs a two-stud fighter's stride, not an adult's.
humanoid.WalkSpeed = MiniConfig.Wander.TravelSpeedStuds
humanoid.AutoRotate = true
end


-- Set the rig up to be moved by the engine rather than by us. The Mini walks
-- with Humanoid:MoveTo from here on, so it needs to be a real physical body:
-- unanchored, standing on the floor, colliding with the world.
local function makePhysical(model: Model)
for _, descendant in model:GetDescendants() do
if descendant:IsA("BasePart") then
descendant.Anchored = false
-- Nothing should be able to shoot, click or trigger the Mini, and it must
-- not block the pathfinding rays that plan its own route.
descendant.CanQuery = false
descendant.CanTouch = false
descendant.CastShadow = false

-- The root is the Humanoid's own collision volume; the limbs hanging off
-- it must not also collide, or the rig snags on its own geometry.
descendant.CanCollide = descendant.Name ~= "HumanoidRootPart"
descendant.Massless = descendant.Name ~= "HumanoidRootPart"

descendant.CollisionGroup = MiniAvatarService.CollisionGroup
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

makePhysical(model)

local humanoid =
model:FindFirstChildOfClass("Humanoid")

if humanoid then
quietenHumanoid(humanoid)
end

local root =
model:FindFirstChild("HumanoidRootPart")

if root and root:IsA("BasePart") then
model.PrimaryPart = root
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


-- Minis are physical bodies now, which means they can be shoved. A player who
-- can barge their own fighter off the bridge is a bug, and twenty Minis piling
-- into each other in a shared world is worse. Both are solved by collision
-- groups rather than by turning collision off, which would drop them through
-- the floor.
local function setUpCollisionGroups()
	for _, name in { MiniAvatarService.CollisionGroup, PLAYER_COLLISION_GROUP } do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end

	-- They still collide with the world -- that is what keeps them on the
	-- bridge -- just not with each other or with people.
	PhysicsService:CollisionGroupSetCollidable(
		MiniAvatarService.CollisionGroup,
		MiniAvatarService.CollisionGroup,
		false
	)
	PhysicsService:CollisionGroupSetCollidable(
		MiniAvatarService.CollisionGroup,
		PLAYER_COLLISION_GROUP,
		false
	)
end

local function claimCharacter(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = PLAYER_COLLISION_GROUP
		end
	end

	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = PLAYER_COLLISION_GROUP
		end
	end)
end

function MiniAvatarService.Init()
	setUpCollisionGroups()

	local function watch(player: Player)
		player.CharacterAdded:Connect(claimCharacter)

		if player.Character then
			claimCharacter(player.Character)
		end
	end

	Players.PlayerAdded:Connect(watch)

	for _, player in Players:GetPlayers() do
		watch(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		descriptionCache[player.UserId] = nil
	end)
end


return MiniAvatarService