--!nonstrict
-- Runtime owner for every player's visible Mini.
--
-- V0.2 goal:
--   Character appears -> Mini appears immediately -> real avatar look swaps in.
--
-- Movement/personality deliberately comes later. This service only proves the
-- most important product promise: "that tiny fighter is ME."

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

local MiniService = {}

local AnalyticsService
local MiniAvatarService

local minisFolder: Folder
local blankTemplate: Model

local minis: { [Player]: Model } = {}
local generations: { [Player]: number } = {}

local function nextGeneration(player: Player): number
local generation = (generations[player] or 0) + 1
generations[player] = generation
return generation
end

local function isCurrent(player: Player, generation: number): boolean
return player.Parent == Players and generations[player] == generation
end

local function destroyMini(player: Player)
local mini = minis[player]
if mini then
minis[player] = nil
mini:Destroy()
end
end

local function placeBesideCharacter(character: Model, mini: Model)
local root = character:FindFirstChild("HumanoidRootPart")

if not root then
root = character:WaitForChild("HumanoidRootPart", 5)
end

if not root or not root:IsA("BasePart") then
return
end

local humanoid = character:FindFirstChildOfClass("Humanoid")

-- Slightly forward and to the player's right so the Mini is immediately
-- visible without spawning underneath the player's feet.
local offset = root.CFrame * CFrame.new(3.2, 0, 2.0)

local facing = CFrame.lookAt(
offset.Position,
offset.Position + root.CFrame.LookVector
)

mini:PivotTo(facing)

-- Put the Mini's feet on approximately the same ground plane as the player.
local characterFloorY =
root.Position.Y
- root.Size.Y * 0.5
- (humanoid and humanoid.HipHeight or 2)

local boxCFrame, boxSize = mini:GetBoundingBox()
local miniFloorY = boxCFrame.Position.Y - boxSize.Y * 0.5

local deltaY = characterFloorY - miniFloorY

mini:PivotTo(
CFrame.new(0, deltaY, 0) * mini:GetPivot()
)
end

local function loadAppearance(
player: Player,
character: Model,
generation: number
)
local timeoutSeconds = MiniConfig.Appearance.FetchTimeoutSeconds
local startedAt = os.clock()

-- The Roblox avatar request itself cannot be cancelled once yielding.
-- The important contract is that gameplay never waits for it. The grey Mini
-- already exists; after this deadline a late result is simply discarded.
task.delay(timeoutSeconds, function()
if not isCurrent(player, generation) then
return
end

local current = minis[player]
if current and current:GetAttribute("AppearanceReady") ~= true then
AnalyticsService.track(
player,
"MiniAppearanceTimeout",
{ timeoutSeconds = timeoutSeconds }
)

if GameConfig.DebugLogging then
warn(
`[MiniService] avatar appearance timed out for {player.Name}`
)
end
end
end)

local realMini = MiniAvatarService.buildAsync(player.UserId)
local elapsed = os.clock() - startedAt

if not isCurrent(player, generation) then
realMini:Destroy()
return
end

-- A result that arrived after the product deadline must not suddenly pop in
-- much later while the player is already doing something else.
if elapsed > timeoutSeconds then
realMini:Destroy()
return
end

-- MiniAvatarService returns Mini_Blank when Roblox's appearance service
-- fails. We already have a correctly-positioned placeholder, so keep it.
if realMini.Name == "Mini_Blank" then
realMini:Destroy()

AnalyticsService.track(
player,
"MiniAppearanceFallback",
{ loadMs = math.round(elapsed * 1000) }
)

return
end

local current = minis[player]
if not current then
realMini:Destroy()
return
end

realMini.Name = `Mini_{player.UserId}`
realMini:SetAttribute("OwnerUserId", player.UserId)
realMini:SetAttribute("AppearanceReady", true)

-- Preserve the exact placeholder position for a visually clean swap.
realMini:PivotTo(current:GetPivot())
realMini.Parent = minisFolder

current:Destroy()
minis[player] = realMini

AnalyticsService.trackOnce(
player,
"MiniAppearanceApplied",
{ loadMs = math.round(elapsed * 1000) }
)

if GameConfig.DebugLogging then
print(
`[MiniService] {player.Name} appearance ready in {math.round(elapsed * 1000)} ms`
)
end
end

local function spawnForCharacter(player: Player, character: Model)
local generation = nextGeneration(player)

destroyMini(player)

AnalyticsService.trackOnce(player, "CharacterLoaded")

-- Instant local clone: zero avatar-network dependency on the spawn path.
local mini = blankTemplate:Clone()

mini.Name = `Mini_{player.UserId}`
mini:SetAttribute("OwnerUserId", player.UserId)
mini:SetAttribute("AppearanceReady", false)

mini.Parent = minisFolder

placeBesideCharacter(character, mini)

minis[player] = mini

AnalyticsService.trackOnce(player, "MiniGenerated")

-- Fetching and building the recognisable appearance happens entirely away
-- from the player/character spawn path.
task.spawn(loadAppearance, player, character, generation)
end

local function onPlayerAdded(player: Player)
player.CharacterAdded:Connect(function(character)
task.defer(spawnForCharacter, player, character)
end)

if player.Character then
task.defer(spawnForCharacter, player, player.Character)
end
end

function MiniService.Init(registry)
AnalyticsService = registry.AnalyticsService
MiniAvatarService = registry.MiniAvatarService

local existing = Workspace:FindFirstChild("Minis")

if existing and existing:IsA("Folder") then
minisFolder = existing
else
if existing then
existing:Destroy()
end

minisFolder = Instance.new("Folder")
minisFolder.Name = "Minis"
minisFolder.Parent = Workspace
end

-- Building an empty Roblox rig may yield once during server boot, but every
-- actual player spawn clones this already-finished template instantly.
blankTemplate = MiniAvatarService.buildBlank()
blankTemplate.Name = "_BlankMiniTemplate"
end

function MiniService.Start()
Players.PlayerAdded:Connect(onPlayerAdded)

Players.PlayerRemoving:Connect(function(player)
nextGeneration(player)
destroyMini(player)
generations[player] = nil
end)

for _, player in Players:GetPlayers() do
onPlayerAdded(player)
end
end

function MiniService.get(player: Player): Model?
return minis[player]
end

return MiniService