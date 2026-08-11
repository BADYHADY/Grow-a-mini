--!nonstrict
-- Turns a player's Roblox avatar into their Mini.
--
-- This is the product. If a Mini does not look recognisably like the person who
-- owns it, nothing else in the game matters -- so the rules here are about
-- preserving identity while staying cheap enough to run 24 of them on a phone.
--
-- Approach: let Roblox build a real R6 rig from the player's HumanoidDescription
-- (correct joints, clothing, faces and accessory welds for free), then reshape
-- it into chibi proportions. We deliberately do NOT clone the player's live
-- character and shrink it -- Rthro bodies, layered clothing and joke-sized
-- accessories turn that into an unreadable blob at 0.35 scale.
--
-- Two identity carriers matter most at this size: the face and the head-level
-- accessory (hair or hat). Everything else is silhouette and colour.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)
local RigScaler = require(Shared.Util.RigScaler)

local APPEARANCE = MiniConfig.Appearance

local MiniAvatarService = {}

type CacheEntry = {
	description: HumanoidDescription,
	expiresAt: number,
}

local descriptionCache: { [number]: CacheEntry } = {}

--[[ Appearance filtering ]]

-- Rank used when trimming down to MaxAccessories. Anything not in the priority
-- list sorts last, so an unrecognised accessory type never displaces hair.
local function accessoryRank(accessoryType: Enum.AccessoryType): number
	for index, candidate in APPEARANCE.AccessoryPriority do
		if candidate == accessoryType then
			return index
		end
	end
	return #APPEARANCE.AccessoryPriority + 1
end

-- Filters the accessory list on the description itself, before the model is
-- built. Cheaper than building everything and deleting half of it, and it keeps
-- layered clothing from ever reaching the mesh-deformation path.
local function trimAccessories(description: HumanoidDescription)
	local accessories = description:GetAccessories(true)

	local kept = {}
	for _, accessory in accessories do
		if accessory.IsLayered and not APPEARANCE.AllowLayeredClothing then
			continue
		end
		table.insert(kept, accessory)
	end

	table.sort(kept, function(a, b)
		return accessoryRank(a.AccessoryType) < accessoryRank(b.AccessoryType)
	end)

	while #kept > APPEARANCE.MaxAccessories do
		table.remove(kept)
	end

	description:SetAccessories(kept, true)
end

-- Joke-sized accessories can only be caught after the model exists, since the
-- description carries an asset id and nothing about its dimensions. Measured
-- before scaling, so the threshold is in normal-avatar studs.
local function removeOversizedAccessories(model: Model): number
	local removed = 0

	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("Accessory") then
			continue
		end

		local handle = descendant:FindFirstChild("Handle")
		if not handle or not handle:IsA("BasePart") then
			continue
		end

		local size = handle.Size
		if math.max(size.X, size.Y, size.Z) > APPEARANCE.MaxAccessoryStuds then
			descendant:Destroy()
			removed += 1
		end
	end

	return removed
end

--[[ Rig setup ]]

-- A Mini never walks, jumps, falls or takes damage through Roblox's state
-- machine -- movement is driven by us. Leaving the machine on costs CPU per
-- Mini per frame for behaviour we actively do not want.
local function quietenHumanoid(humanoid: Humanoid)
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
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

--[[ Public API ]]

-- Cached avatar lookup. Always server side and always from a trusted UserId --
-- a client-supplied id would let anyone render anyone.
function MiniAvatarService.getDescription(userId: number): HumanoidDescription?
	local cached = descriptionCache[userId]
	if cached and os.clock() < cached.expiresAt then
		return cached.description
	end

	local ok, result = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)

	if not ok then
		warn(`[MiniAvatarService] avatar fetch failed for {userId}: {result}`)
		return nil
	end

	descriptionCache[userId] = {
		description = result,
		expiresAt = os.clock() + APPEARANCE.CacheSeconds,
	}

	return result
end

-- The neutral Mini shown while a real appearance is still loading, and the
-- fallback when a fetch fails. Spawning must never block on the network.
function MiniAvatarService.buildBlank(): Model
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = "Mini_Blank"

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Color = Color3.fromRGB(156, 156, 156)
		end
	end

	MiniAvatarService.finalise(model)
	return model
end

-- Applies chibi proportions and the cheap-rig settings. Split out so the spike
-- harness can build a rig, inspect it, and finalise it separately.
function MiniAvatarService.finalise(model: Model)
	local removed = removeOversizedAccessories(model)
	if removed > 0 and GameConfig.DebugLogging then
		print(`[MiniAvatarService] dropped {removed} oversized accessor{removed == 1 and "y" or "ies"}`)
	end

	RigScaler.apply(model, RigScaler.chibiScales(MiniConfig.Scale))
	makeLightweight(model)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		quietenHumanoid(humanoid)
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
		root.Anchored = true
	end
end

-- Builds the Mini for a user. Never throws and never returns nil: a failed
-- avatar fetch produces a blank Mini rather than a player with no Mini at all.
function MiniAvatarService.build(userId: number): Model
	local description = MiniAvatarService.getDescription(userId)
	if not description then
		return MiniAvatarService.buildBlank()
	end

	-- Work on a copy: the cached description is shared, and trimming mutates it.
	local trimmed = description:Clone()
	trimAccessories(trimmed)

	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(trimmed, Enum.HumanoidRigType.R6)
	end)

	if not ok or not model then
		warn(`[MiniAvatarService] rig build failed for {userId}: {model}`)
		return MiniAvatarService.buildBlank()
	end

	model.Name = `Mini_{userId}`
	MiniAvatarService.finalise(model)
	return model
end

-- Removes the Humanoid entirely and replaces it with the minimum needed to play
-- animations. Kept separate from finalise so the spike can A/B whether clothing
-- and faces still render without a Humanoid before we commit to it.
function MiniAvatarService.stripHumanoid(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	-- Animator.Parent is locked after creation, so the Humanoid's Animator cannot
	-- be moved across -- attempting it throws. Build a fresh one and let the old
	-- Animator die with its Humanoid.
	local controller = Instance.new("AnimationController")
	controller.Name = "AnimationController"
	Instance.new("Animator").Parent = controller
	controller.Parent = model

	humanoid:Destroy()
end

function MiniAvatarService.Init()
	Players.PlayerRemoving:Connect(function(player)
		descriptionCache[player.UserId] = nil
	end)
end

return MiniAvatarService
