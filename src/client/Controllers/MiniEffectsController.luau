--!nonstrict
-- The moments worth noticing: a fist landing, and a level being earned.
--
-- Kept apart from MiniController (which owns where the Mini is and how it moves)
-- and from MiniStatsController (which owns the card). This file owns nothing but
-- things that flash and fade.
--
-- Everything here is driven off replicated attributes, so a Mini three plots away
-- pops for its own owner and for everyone watching.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)

local GROWTH = MiniConfig.Growth

-- Roblox ships these; no upload needed and no external dependency to break.
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local MiniEffectsController = {}

local minisFolder: Folder
local connections: { [Model]: { RBXScriptConnection } } = {}

local function torsoOf(model: Model): BasePart?
	return model:FindFirstChild("UpperTorso")
		or model:FindFirstChild("Torso")
		or model.PrimaryPart
end

-- A level is the payoff for a dozen punches, so it gets light, sparks and a
-- sound -- but all of it is gone in under half a second, because early on this
-- fires every few seconds and anything lingering becomes visual noise.
local function playLevelUp(model: Model)
	local torso = torsoOf(model)

	if not torso then
		return
	end

	local burst = Instance.new("ParticleEmitter")
	burst.Name = "LevelUpBurst"
	burst.Texture = SPARK_TEXTURE
	burst.Color = ColorSequence.new(Color3.fromRGB(255, 226, 138))
	burst.LightEmission = 1
	burst.Lifetime = NumberRange.new(0.25, 0.5)
	burst.Speed = NumberRange.new(2.5, 5)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Rate = 0
	-- Sized against the Mini, so a grown fighter throws a bigger burst.
	burst.Size = NumberSequence.new(0.35 * model:GetScale())
	burst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	burst.Parent = torso
	burst:Emit(24)

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 150)
	light.Brightness = 4
	light.Range = 10
	light.Parent = torso

	local sound = Instance.new("Sound")
	sound.SoundId = GROWTH.LevelUpSoundId
	sound.Volume = GROWTH.LevelUpSoundVolume
	sound.RollOffMaxDistance = GROWTH.LevelUpSoundMaxDistance
	sound.Parent = torso
	sound:Play()

	TweenService:Create(
		light,
		TweenInfo.new(GROWTH.LevelUpFlashSeconds, Enum.EasingStyle.Quad),
		{ Brightness = 0 }
	):Play()

	Debris:AddItem(burst, 1)
	Debris:AddItem(light, GROWTH.LevelUpFlashSeconds + 0.1)
	Debris:AddItem(sound, 3)
end

-- Growth is applied by the server in one step. Easing the model into its new
-- size on the client turns a pop into something that reads as growing.
local function playGrowth(model: Model, growth: number)
	local target = MiniConfig.Scale.Overall * growth
	local current = model:GetScale()

	if math.abs(current - target) < 0.0005 then
		return
	end

	-- Overshoot slightly, so the Mini looks like it flexed rather than like it
	-- was resized.
	local scaleValue = Instance.new("NumberValue")
	scaleValue.Value = current

	local connection = scaleValue.Changed:Connect(function(value)
		if model.Parent then
			model:ScaleTo(value)
		end
	end)

	local tween = TweenService:Create(
		scaleValue,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Value = target }
	)

	tween.Completed:Connect(function()
		connection:Disconnect()
		scaleValue:Destroy()
	end)

	tween:Play()
end

local function watch(model: Model)
	if connections[model] then
		return
	end

	local tracked = {}
	connections[model] = tracked

	local lastLevel = model:GetAttribute("Level")

	table.insert(
		tracked,
		model:GetAttributeChangedSignal("Level"):Connect(function()
			local level = model:GetAttribute("Level")

			-- Only a level that went UP is a celebration; the first publish on a
			-- returning player's Mini is not.
			if type(level) == "number" and type(lastLevel) == "number" and level > lastLevel then
				playLevelUp(model)
			end

			lastLevel = level
		end)
	)

	table.insert(
		tracked,
		model:GetAttributeChangedSignal("Growth"):Connect(function()
			local growth = model:GetAttribute("Growth")

			if type(growth) == "number" then
				playGrowth(model, growth)
			end
		end)
	)
end

local function forget(model: Instance)
	local tracked = connections[model]

	if not tracked then
		return
	end

	for _, connection in tracked do
		connection:Disconnect()
	end

	connections[model] = nil
end

function MiniEffectsController.Init()
	minisFolder = Workspace:WaitForChild("Minis")
end

function MiniEffectsController.Start()
	for _, child in minisFolder:GetChildren() do
		if child:IsA("Model") then
			watch(child)
		end
	end

	minisFolder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			watch(child)
		end
	end)

	minisFolder.ChildRemoved:Connect(forget)
end

-- Called by MiniController the moment a fist lands, because that is the only
-- place that knows the exact frame.
function MiniEffectsController.punchImpact(bagPart: BasePart, scale: number)
	local spark = Instance.new("ParticleEmitter")
	spark.Texture = SPARK_TEXTURE
	spark.Color = ColorSequence.new(Color3.fromRGB(255, 240, 200))
	spark.LightEmission = 1
	spark.Lifetime = NumberRange.new(0.12, 0.22)
	spark.Speed = NumberRange.new(1.5, 3)
	spark.SpreadAngle = Vector2.new(140, 140)
	spark.Rate = 0
	spark.Size = NumberSequence.new(0.22 * scale)
	spark.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	spark.Parent = bagPart
	spark:Emit(6)

	Debris:AddItem(spark, 0.6)
end

return MiniEffectsController
