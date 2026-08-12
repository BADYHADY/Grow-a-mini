--!nonstrict
-- The two buttons the whole game is played with.
--
-- One says where the Mini should be: with you, or on the bag. The other sends it
-- out to fight and brings it back. That is the entire control scheme, and it has
-- to stay that small -- the player is the coach, not the fighter.
--
-- Both buttons label themselves from the Mini's actual state, so the screen can
-- never claim the Mini is doing something it is not.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local OUTLINE = Color3.fromRGB(16, 16, 20)
local IDLE_COLOR = Color3.fromRGB(38, 42, 52)
local FOLLOW_COLOR = Color3.fromRGB(64, 132, 224)
local TOWER_COLOR = Color3.fromRGB(196, 62, 62)

local PRESS = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local CommandController = {}

local followButton: TextButton
local towerButton: TextButton
local mini: Model?

local function styleButton(button: TextButton, color: Color3)
	button.BackgroundColor3 = color
	button.AutoButtonColor = true
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBlack
	button.TextScaled = true
	button.TextColor3 = Color3.fromRGB(255, 255, 255)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = OUTLINE
	stroke.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = button

	local scale = Instance.new("UIScale")
	scale.Parent = button

	-- Touch targets get a press that is felt, not just seen.
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, PRESS, { Scale = 0.94 }):Play()
	end)

	local function release()
		TweenService:Create(scale, PRESS, { Scale = 1 }):Play()
	end

	button.MouseButton1Up:Connect(release)
	button.MouseLeave:Connect(release)
end

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "MiniCommands"
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Bottom right, above the thumb on a phone and out of the way of the
	-- jump button.
	local holder = Instance.new("Frame")
	holder.Name = "Buttons"
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(1, -16, 1, -16)
	holder.Size = UDim2.fromOffset(180, 128)
	holder.BackgroundTransparency = 1
	holder.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = holder

	followButton = Instance.new("TextButton")
	followButton.Name = "Follow"
	followButton.Size = UDim2.fromOffset(180, 56)
	followButton.LayoutOrder = 1
	followButton.Text = "FOLLOW ME"
	followButton.Parent = holder
	styleButton(followButton, IDLE_COLOR)

	towerButton = Instance.new("TextButton")
	towerButton.Name = "Tower"
	towerButton.Size = UDim2.fromOffset(180, 56)
	towerButton.LayoutOrder = 2
	towerButton.Text = "SEND TO TOWER"
	towerButton.Parent = holder
	styleButton(towerButton, TOWER_COLOR)

	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function refresh()
	local action = mini and mini:GetAttribute("ActionState")

	-- Following: the button becomes the way back to work. Otherwise it is the
	-- way to call the Mini over.
	if action == "Follow" then
		followButton.Text = "GO TRAIN"
		followButton.BackgroundColor3 = FOLLOW_COLOR
	else
		followButton.Text = "FOLLOW ME"
		followButton.BackgroundColor3 = IDLE_COLOR
	end

	if action == "Fighting" then
		towerButton.Text = "CALL BACK"
		towerButton.BackgroundColor3 = IDLE_COLOR
	else
		towerButton.Text = "SEND TO TOWER"
		towerButton.BackgroundColor3 = TOWER_COLOR
	end
end

local function watchMini(model: Model)
	if model:GetAttribute("OwnerUserId") ~= Players.LocalPlayer.UserId then
		return
	end

	mini = model
	refresh()

	model:GetAttributeChangedSignal("ActionState"):Connect(refresh)
end

function CommandController.Start()
	build()

	local minis = Workspace:WaitForChild("Minis")

	for _, child in minis:GetChildren() do
		if child:IsA("Model") then
			watchMini(child)
		end
	end

	minis.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			-- The appearance swap replaces the model, and the buttons have to
			-- follow the replacement.
			task.defer(watchMini, child)
		end
	end)

	followButton.Activated:Connect(function()
		local action = mini and mini:GetAttribute("ActionState")
		Remotes.send("MiniCommand", if action == "Follow" then "Train" else "Follow")
	end)

	towerButton.Activated:Connect(function()
		Remotes.send("MiniCommand", "Tower")
	end)
end

return CommandController
