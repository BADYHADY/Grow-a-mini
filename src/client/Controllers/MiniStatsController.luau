--!nonstrict
-- The card above the Mini's head: who it is, how strong it has become, and how
-- close it is to being ready for a fight.
--
-- This is the readout the training loop is FOR. A punch that does not visibly
-- move one of these numbers is a punch the player has no reason to watch, so
-- every number here is big, outlined, and reacts when it changes.
--
-- Everything is read from attributes TrainingService publishes. The client never
-- computes a stat, it only draws one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)

-- Readable while standing on the plot, gone by the time you have walked to the
-- next one. Twenty floating cards across a busy server is a wall of text.
local VIEW_DISTANCE = 90

-- Notches in the health bar. Discrete chunks read as progress at a glance in a
-- way a smooth sliver of colour does not, especially on a phone.
local BAR_SEGMENTS = 6

local WATCHED = {
	"Level",
	"Power",
	"Health",
	"MaxHealth",
	"Xp",
	"XpForLevel",
	"ActionState",
}

local NAME_COLOR = Color3.fromRGB(126, 236, 138)
local LEVEL_COLOR = Color3.fromRGB(143, 211, 255)
local OUTLINE = Color3.fromRGB(16, 16, 20)

-- The health bar IS the readiness indicator: red on the floor, white when the
-- Mini is topped up and worth sending out.
local HURT_COLOR = Color3.fromRGB(214, 48, 49)
local FULL_COLOR = Color3.fromRGB(255, 255, 255)
local XP_COLOR = Color3.fromRGB(255, 206, 92)

local FILL_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_BACK = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local MiniStatsController = {}

type Card = {
	gui: BillboardGui,
	title: TextLabel,
	power: TextLabel,
	health: TextLabel,
	healthScale: UIScale,
	fill: Frame,
	status: TextLabel,
	lastLevel: number,
	connections: { RBXScriptConnection },
}

local minisFolder: Folder
local cards: { [Model]: Card } = {}

local function ownerOf(model: Model): Player?
	local userId = model:GetAttribute("OwnerUserId")

	if type(userId) ~= "number" then
		return nil
	end

	return Players:GetPlayerByUserId(userId)
end

-- The chunky cartoon outline every readable Roblox nameplate has. TextStroke is
-- a single thin pixel; UIStroke actually traces the glyphs.
local function outline(label: TextLabel, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = OUTLINE
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label
	return stroke
end

local function makeLabel(name: string, parent: Instance): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.RichText = true
	label.Parent = parent
	return label
end

local function build(model: Model, owner: Player): Card
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "MiniStats"
	-- Sized in studs, so it stays proportional to the Mini rather than swelling
	-- when the camera comes close.
	billboard.Size = UDim2.fromScale(4.6, 2.0)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 0.95, 0)
	billboard.MaxDistance = VIEW_DISTANCE
	billboard.AlwaysOnTop = false
	billboard.ResetOnSpawn = false

	local title = makeLabel("Title", billboard)
	title.Size = UDim2.fromScale(1, 0.36)
	title.Text = string.upper(owner.DisplayName)
	outline(title, 3)

	-- Icons and values sit on one row, each in its own label, so a value can be
	-- popped on change without moving the rest of the line.
	local row = Instance.new("Frame")
	row.Name = "Stats"
	row.Position = UDim2.fromScale(0, 0.36)
	row.Size = UDim2.fromScale(1, 0.3)
	row.BackgroundTransparency = 1
	row.Parent = billboard

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.04, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local power = makeLabel("Power", row)
	power.Size = UDim2.fromScale(0.4, 1)
	power.LayoutOrder = 1
	power.Text = "⚔️ 0"
	outline(power, 2.5)

	local health = makeLabel("Health", row)
	health.Size = UDim2.fromScale(0.4, 1)
	health.LayoutOrder = 2
	health.Text = "❤️ 0"
	outline(health, 2.5)

	-- Pops on every heal, which is what makes a punch feel like it paid out.
	local healthScale = Instance.new("UIScale")
	healthScale.Parent = health

	-- The big bar is XP, not health. It is the one that visibly fills while you
	-- watch, and the one that pays out a level -- so it gets the space. Health is
	-- carried by the colour of the number next to the heart instead.
	local bar = Instance.new("Frame")
	bar.Name = "XpBar"
	bar.Position = UDim2.fromScale(0.11, 0.72)
	bar.Size = UDim2.fromScale(0.78, 0.2)
	bar.BackgroundColor3 = Color3.fromRGB(26, 28, 34)
	bar.BorderSizePixel = 0
	bar.Parent = billboard

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar

	local barStroke = Instance.new("UIStroke")
	barStroke.Thickness = 2.5
	barStroke.Color = OUTLINE
	barStroke.Parent = bar

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = XP_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = bar

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	-- Notches drawn OVER the fill, so the bar reads as chunks being filled in
	-- rather than a bar that happens to have lines on it.
	for index = 1, BAR_SEGMENTS - 1 do
		local notch = Instance.new("Frame")
		notch.Name = `Notch{index}`
		notch.AnchorPoint = Vector2.new(0.5, 0.5)
		notch.Position = UDim2.fromScale(index / BAR_SEGMENTS, 0.5)
		notch.Size = UDim2.new(0, 2, 1, 0)
		notch.BackgroundColor3 = OUTLINE
		notch.BorderSizePixel = 0
		notch.ZIndex = 3
		notch.Parent = bar
	end

	local status = makeLabel("Status", bar)
	status.Size = UDim2.fromScale(1, 1)
	status.ZIndex = 4
	status.Text = ""
	outline(status, 2)


	billboard.Adornee = model:FindFirstChild("Head") or model.PrimaryPart
	billboard.Parent = model

	return {
		gui = billboard,
		title = title,
		power = power,
		health = health,
		healthScale = healthScale,
		fill = fill,
		status = status,
		lastLevel = 0,
		connections = {},
	}
end

local function pop(scale: UIScale, amount: number)
	TweenService:Create(scale, POP_OUT, { Scale = amount }):Play()

	task.delay(POP_OUT.Time, function()
		if scale.Parent then
			TweenService:Create(scale, POP_BACK, { Scale = 1 }):Play()
		end
	end)
end

local function refresh(model: Model, card: Card)
	if not card.gui.Adornee then
		card.gui.Adornee = model:FindFirstChild("Head") or model.PrimaryPart
	end

	local owner = ownerOf(model)
	local level = model:GetAttribute("Level")
	local power = model:GetAttribute("Power")
	local health = model:GetAttribute("Health")
	local maxHealth = model:GetAttribute("MaxHealth")

	if owner and type(level) == "number" then
		card.title.Text = string.format(
			'<font color="#%s">%s</font>  <font color="#%s">LV.%d</font>',
			NAME_COLOR:ToHex(),
			string.upper(owner.DisplayName),
			LEVEL_COLOR:ToHex(),
			level
		)

		-- A level up is the moment the training paid off. Say so with the whole
		-- card, not just a digit ticking over.
		if card.lastLevel ~= 0 and level > card.lastLevel then
			pop(card.healthScale, 1.35)
		end

		card.lastLevel = level
	end

	if type(power) == "number" then
		card.power.Text = `⚔️ {Format.abbreviate(power)}`
	end


	if type(health) ~= "number" or type(maxHealth) ~= "number" or maxHealth <= 0 then
		return
	end

	local previous = card.health.Text
	card.health.Text = `❤️ {Format.abbreviate(health)}`

	if previous ~= card.health.Text then
		pop(card.healthScale, 1.18)
	end

	-- Condition is told by COLOUR, not by a word or a second bar. Deep red is a
	-- Mini that just got knocked out; the red bleeds out to white as it fills
	-- back up, so the player reads its state off one number at a glance.
	card.health.TextColor3 =
		HURT_COLOR:Lerp(FULL_COLOR, math.clamp(health / maxHealth, 0, 1))

	local xp = model:GetAttribute("Xp")
	local xpForLevel = model:GetAttribute("XpForLevel")

	if type(xp) == "number" and type(xpForLevel) == "number" and xpForLevel > 0 then
		TweenService:Create(card.fill, FILL_TWEEN, {
			Size = UDim2.fromScale(math.clamp(xp / xpForLevel, 0, 1), 1),
		}):Play()
	end

	local action = model:GetAttribute("ActionState")

	if action == "Fighting" then
		card.status.Text = `FLOOR {model:GetAttribute("TowerFloor") or 1}`
	elseif action == "Returning" then
		card.status.Text = "KNOCKED OUT"
	else
		card.status.Text = ""
	end
end

local function register(instance: Instance)
	if not instance:IsA("Model") then
		return
	end

	task.defer(function()
		if not instance.Parent or cards[instance] then
			return
		end

		local owner = ownerOf(instance)

		if not owner then
			return
		end

		local card = build(instance, owner)
		cards[instance] = card

		for _, attribute in WATCHED do
			table.insert(
				card.connections,
				instance:GetAttributeChangedSignal(attribute):Connect(function()
					refresh(instance, card)
				end)
			)
		end

		-- The stats may already have been published before this card existed.
		refresh(instance, card)
	end)
end

local function unregister(instance: Instance)
	local card = cards[instance]

	if not card then
		return
	end

	for _, connection in card.connections do
		connection:Disconnect()
	end

	card.gui:Destroy()
	cards[instance] = nil
end

function MiniStatsController.Init()
	minisFolder = Workspace:WaitForChild("Minis")
end

function MiniStatsController.Start()
	for _, child in minisFolder:GetChildren() do
		register(child)
	end

	minisFolder.ChildAdded:Connect(register)
	minisFolder.ChildRemoved:Connect(unregister)
end

return MiniStatsController
