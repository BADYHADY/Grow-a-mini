--!nonstrict
-- Screen furniture. Right now that means one thing: how much gold you have.
--
-- Coins live here rather than on the Mini's card because they are the PLAYER's,
-- not the fighter's -- and because a number that changes while you are looking
-- at a shop prompt has to be on screen, not floating in the world behind you.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Net.Remotes)

local GOLD = Color3.fromRGB(255, 206, 92)
local OUTLINE = Color3.fromRGB(16, 16, 20)

local POP_OUT = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_BACK = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local HudController = {}

local amount: TextLabel
local scale: UIScale
local coins = 0

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "Hud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Top left, sized in offset rather than scale: a currency pill that grows
	-- with the screen looks wrong on a tablet and enormous on a phone.
	local pill = Instance.new("Frame")
	pill.Name = "Coins"
	pill.Position = UDim2.new(0, 12, 0, 12)
	pill.Size = UDim2.fromOffset(150, 44)
	pill.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = pill

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = OUTLINE
	stroke.Parent = pill

	scale = Instance.new("UIScale")
	scale.Parent = pill

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Position = UDim2.fromOffset(8, 6)
	icon.Size = UDim2.fromOffset(32, 32)
	icon.Font = Enum.Font.GothamBlack
	icon.TextScaled = true
	icon.Text = "🪙"
	icon.Parent = pill

	amount = Instance.new("TextLabel")
	amount.Name = "Amount"
	amount.BackgroundTransparency = 1
	amount.Position = UDim2.fromOffset(44, 6)
	amount.Size = UDim2.fromOffset(96, 32)
	amount.Font = Enum.Font.GothamBlack
	amount.TextScaled = true
	amount.TextXAlignment = Enum.TextXAlignment.Left
	amount.TextColor3 = GOLD
	amount.Text = "0"
	amount.Parent = pill

	local amountStroke = Instance.new("UIStroke")
	amountStroke.Thickness = 2.5
	amountStroke.Color = OUTLINE
	amountStroke.Parent = amount

	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function setCoins(value: number)
	local gained = value > coins
	coins = value

	amount.Text = Format.abbreviate(value)

	if not gained then
		return
	end

	-- Earning has to be felt somewhere on screen, or a tower run reads as
	-- nothing happening.
	TweenService:Create(scale, POP_OUT, { Scale = 1.12 }):Play()

	task.delay(POP_OUT.Time, function()
		TweenService:Create(scale, POP_BACK, { Scale = 1 }):Play()
	end)
end

function HudController.Start()
	build()

	Remotes.on("CurrencyChanged", function(currency: string, value: number)
		if currency ~= "Coins" or type(value) ~= "number" then
			return
		end

		setCoins(value)
	end)
end

return HudController
