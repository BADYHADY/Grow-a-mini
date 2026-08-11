--!nonstrict
-- Studio-only performance HUD.
--
-- Built now rather than later because the mobile budget (30 FPS on a 4 GB
-- Android with 24 minis and 40 enemies) is a stated requirement, and a
-- requirement nobody can see the current value of is a requirement that gets
-- quietly broken. Other systems push their counts in via setCounter.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)

-- Frame times are noisy; a one-second window is stable enough to read while
-- still reacting fast enough to catch a spike you just caused.
local SAMPLE_WINDOW = 1.0

local DebugController = {}

local counters: { [string]: number } = {}
local label: TextLabel?

local frameCount = 0
local windowStart = 0
local worstFrameMs = 0

function DebugController.setCounter(name: string, value: number)
	counters[name] = value
end

local function buildGui()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 1000

	local text = Instance.new("TextLabel")
	text.Name = "Readout"
	text.AnchorPoint = Vector2.new(1, 0)
	text.Position = UDim2.new(1, -8, 0, 8)
	text.Size = UDim2.fromOffset(230, 76)
	text.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	text.BackgroundTransparency = 0.45
	text.TextColor3 = Color3.fromRGB(150, 255, 170)
	text.Font = Enum.Font.Code
	text.TextSize = 13
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Text = ""
	text.Parent = screenGui

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingTop = UDim.new(0, 4)
	padding.Parent = text

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = text

	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	label = text
end

local function refresh(fps: number)
	if not label then
		return
	end

	local ping = math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())

	local lines = {
		string.format("%d fps   worst %.1f ms", fps, worstFrameMs),
		string.format("ping %d ms", ping),
	}

	for name, value in counters do
		table.insert(lines, string.format("%s %d", name, value))
	end

	label.Text = table.concat(lines, "\n")

	-- Green above 45, amber 30-45, red below the mobile floor.
	local color = Color3.fromRGB(150, 255, 170)
	if fps < 30 then
		color = Color3.fromRGB(255, 120, 120)
	elseif fps < 45 then
		color = Color3.fromRGB(255, 210, 120)
	end
	label.TextColor3 = color
end

function DebugController.Start()
	if not GameConfig.DebugLogging then
		return
	end

	buildGui()
	windowStart = os.clock()

	RunService.RenderStepped:Connect(function(deltaTime)
		frameCount += 1
		worstFrameMs = math.max(worstFrameMs, deltaTime * 1000)

		local now = os.clock()
		local elapsed = now - windowStart
		if elapsed >= SAMPLE_WINDOW then
			refresh(math.floor(frameCount / elapsed + 0.5))
			frameCount = 0
			worstFrameMs = 0
			windowStart = now
		end
	end)
end

return DebugController
