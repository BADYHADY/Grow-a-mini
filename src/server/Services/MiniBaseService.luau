--!nonstrict
-- V0.4A: the player's personal Mini Base.
--
-- Physical world-space readability instead of menus. The player should spawn,
-- look around once, and understand: "this is mine, and that is where my Mini
-- trains." Nothing here explains itself with text beyond a sign.
--
-- Art comes from ServerStorage.Assets (Dojo, Punchingbag). Those are MeshPart
-- models and live in the place file, not in Rojo -- Rojo owns code, the place
-- owns art. Their dimensions are MEASURED at boot rather than hardcoded, so
-- re-exporting a model with different proportions cannot silently bury the
-- punching bag inside the floor.
--
-- SCOPE LOCK: this slice builds the place and nothing else. No training, no
-- Power, no animation, no ActionState. Those are V0.4B onward.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MiniConfig = require(Shared.Config.MiniConfig)

-- The dojo is the MINI's home and training gym, not the player's. It is built
-- at the same scale as the Mini, so the player stands over it like a toy set --
-- which is the whole "tiny fighter" fantasy. Tying it to the Mini's own scale
-- means the two can never drift out of proportion with each other.
local MINI_SCALE = MiniConfig.Scale.Overall

local CONFIG = {
	-- Bases sit in a grid away from the default spawn, so the world reads as
	-- "everyone has their own plot" the moment you look around.
	Origin = Vector3.new(0, 0, 90),
	SlotSpacing = 30,
	SlotsPerRow = 5,
	MaxSlots = 20,

	-- The plot carries a full-size player walking around a Mini-size dojo AND a
	-- Mini-size pit, so it is sized for the player even though everything
	-- standing on it is not. Wide rather than deep: the two halves of the loop
	-- sit side by side, both visible from where the player spawns.
	PlotSize = Vector3.new(22, 1, 14),

	-- Dojo on the left, pit on the right. The Mini's whole life is a walk
	-- between these two points.
	DojoOffsetX = -4.0,
	PitOffsetX = 6.0,
	PitRadius = 2.4,
	PlotColor = Color3.fromRGB(58, 62, 72),
	TrimColor = Color3.fromRGB(196, 148, 100),

	-- The dojo model is open on its -Z face, so everything the Mini should be
	-- seen doing is arranged along that axis. These offsets are authored
	-- against the full-size model and shrink with it.
	BagOffsetZ = 4.0 * MINI_SCALE,
	TrainingOffsetZ = 1.4 * MINI_SCALE,
	-- How far in front of the BAG BODY the Mini stands to punch it. Measured
	-- against the bag itself rather than the stand, because the bag hangs off
	-- one side of its frame and a Mini aimed at the frame punches thin air.
	-- Tuned by measuring the Mini's actual reach at full extension against the
	-- bag's radius in-game: close enough that the fist presses into the bag.
	StandOffFromBagZ = 1.70 * MINI_SCALE,
	SignOffsetZ = -8.0 * MINI_SCALE,

	-- The player is NOT scaled, so their standing spot and the sign height are
	-- in player units.
	PlayerSpawnOffsetZ = -5.0,
	SignClearance = 2.4,
}

local Signal = require(Shared.Util.Signal)

local MiniBaseService = {}

-- (player, base) -- fired once per base, after every prop exists on it.
MiniBaseService.BaseCreated = Signal.new()

local AnalyticsService

local basesFolder: Folder
local dojoTemplate: Model
local bagTemplate: Model

-- Measured from the templates at boot. See the header for why.
local metrics = {
	dojoPivotToBottom = 0,
	dojoFloorTopFromPivot = 0,
	dojoHeight = 0,
	bagPivotToBottom = 0,
}

local bases: { [Player]: Model } = {}
local slotOwners: { [number]: Player } = {}

local function claimSlot(player: Player): number?
	for slot = 1, CONFIG.MaxSlots do
		if slotOwners[slot] == nil then
			slotOwners[slot] = player
			return slot
		end
	end
	return nil
end

local function releaseSlot(player: Player)
	for slot, owner in slotOwners do
		if owner == player then
			slotOwners[slot] = nil
		end
	end
end

local function slotCFrame(slot: number): CFrame
	local index = slot - 1
	local column = index % CONFIG.SlotsPerRow
	local row = math.floor(index / CONFIG.SlotsPerRow)

	-- Centre the grid on the origin so the first few players are not all
	-- crammed against one edge of the world.
	local xOffset = (column - (CONFIG.SlotsPerRow - 1) / 2) * CONFIG.SlotSpacing

	return CFrame.new(CONFIG.Origin + Vector3.new(xOffset, 0, row * CONFIG.SlotSpacing))
end

--[[ Template measurement ]]

local function pivotToBottom(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	return model:GetPivot().Position.Y - (boxCFrame.Position.Y - boxSize.Y * 0.5)
end

local function measureTemplates()
	metrics.dojoPivotToBottom = pivotToBottom(dojoTemplate)
	metrics.bagPivotToBottom = pivotToBottom(bagTemplate)

	local _, dojoSize = dojoTemplate:GetBoundingBox()
	metrics.dojoHeight = dojoSize.Y

	-- The interior floor is what the Mini and the bag actually stand on, and it
	-- sits above the model's lowest point. Falling back to the bounding box
	-- bottom would sink both of them into the floorboards.
	local floor = dojoTemplate:FindFirstChild("dojoFloor_Node")
	if floor then
		local floorCFrame, floorSize = floor:GetBoundingBox()
		local floorTop = floorCFrame.Position.Y + floorSize.Y * 0.5
		metrics.dojoFloorTopFromPivot = floorTop - dojoTemplate:GetPivot().Position.Y
	else
		warn("[MiniBaseService] dojoFloor_Node missing; standing things on the model's base instead")
		metrics.dojoFloorTopFromPivot = -metrics.dojoPivotToBottom
	end
end

-- Y of the dojo's walkable interior floor, in world space, for a given slot.
local function interiorFloorY(): number
	local plotTop = CONFIG.PlotSize.Y
	return plotTop + metrics.dojoPivotToBottom + metrics.dojoFloorTopFromPivot
end

--[[ Building ]]

local function makePart(name: string, size: Vector3, color: Color3, cframe: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.CFrame = cframe
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- The pit is where training gets spent. Deliberately a bare ring on the same
-- plot rather than a separate world: the player has to be able to watch the Mini
-- walk from the bag to the fight and back without moving the camera.
local function buildPit(base: Model, origin: CFrame)
	local floor = makePart(
		"Pit",
		Vector3.new(CONFIG.PitRadius * 2, 0.4, CONFIG.PitRadius * 2),
		Color3.fromRGB(122, 48, 46),
		origin * CFrame.new(CONFIG.PitOffsetX, CONFIG.PlotSize.Y + 0.2, 0),
		base
	)
	floor.Shape = Enum.PartType.Cylinder
	-- A cylinder part's flat faces point along X, so it has to be tipped to lie
	-- down as a floor.
	floor.CFrame = floor.CFrame * CFrame.Angles(0, 0, math.rad(90))
	floor.Material = Enum.Material.Sand

	local rim = makePart(
		"PitRim",
		Vector3.new(CONFIG.PitRadius * 2 + 0.8, 0.25, CONFIG.PitRadius * 2 + 0.8),
		Color3.fromRGB(58, 62, 72),
		origin * CFrame.new(CONFIG.PitOffsetX, CONFIG.PlotSize.Y + 0.08, 0),
		base
	)
	rim.Shape = Enum.PartType.Cylinder
	rim.CFrame = rim.CFrame * CFrame.Angles(0, 0, math.rad(90))

	-- The post the player walks up to and presses. TowerService fills in the
	-- text and does the work; the base only owns the furniture.
	local post = makePart(
		"TowerPost",
		Vector3.new(0.8, 3.2, 0.8),
		Color3.fromRGB(38, 40, 48),
		origin * CFrame.new(
			CONFIG.PitOffsetX,
			CONFIG.PlotSize.Y + 1.6,
			-(CONFIG.PitRadius + 1.4)
		),
		base
	)
	post.Material = Enum.Material.Metal

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TowerPrompt"
	prompt.ObjectText = "TOWER"
	prompt.ActionText = "SEND MINI"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = post
end

-- Where the coins go. Stands beside the dojo opening so the upgrade is read in
-- the same glance as the thing it upgrades.
local function buildBagPost(base: Model, origin: CFrame)
	local post = makePart(
		"BagPost",
		Vector3.new(0.8, 3.0, 0.8),
		Color3.fromRGB(196, 148, 100),
		origin * CFrame.new(CONFIG.DojoOffsetX - 3.2, CONFIG.PlotSize.Y + 1.5, -3.0),
		base
	)
	post.Material = Enum.Material.WoodPlanks

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BagPrompt"
	prompt.ObjectText = "PUNCHING BAG"
	prompt.ActionText = "UPGRADE"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = post
end

local function buildSign(player: Player, base: Model, origin: CFrame)
	local height = CONFIG.PlotSize.Y + metrics.dojoHeight + CONFIG.SignClearance

	local anchor = makePart(
		"SignAnchor",
		Vector3.new(0.6, 0.6, 0.6),
		Color3.fromRGB(30, 32, 38),
		origin * CFrame.new(0, height, CONFIG.SignOffsetZ),
		base
	)
	anchor.Transparency = 1
	anchor.CanCollide = false

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BaseSign"
	-- Wide enough that a long username shrinks rather than wrapping onto two
	-- lines, which reads as broken rather than as a sign.
	billboard.Size = UDim2.fromScale(18, 4)
	billboard.AlwaysOnTop = false
	-- Readable across the plot but not from the far side of the map, so a busy
	-- server does not turn into a wall of floating text.
	billboard.MaxDistance = 160
	billboard.Parent = anchor

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextWrapped = false
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextStrokeTransparency = 0.3
	title.Text = string.upper(player.Name) .. "'S MINI BASE"
	title.Parent = billboard

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Position = UDim2.fromScale(0, 0.6)
	subtitle.Size = UDim2.fromScale(1, 0.4)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamBold
	subtitle.TextScaled = true
	subtitle.TextColor3 = Color3.fromRGB(255, 206, 92)
	subtitle.TextStrokeTransparency = 0.35
	subtitle.Text = "TRAINER LV.1"
	subtitle.Parent = billboard
end

local function buildBase(player: Player, slot: number): Model
	local origin = slotCFrame(slot)
	local plotTop = CONFIG.PlotSize.Y

	local base = Instance.new("Model")
	base.Name = `MiniBase_{player.UserId}`
	base:SetAttribute("OwnerUserId", player.UserId)
	base:SetAttribute("Slot", slot)

	local plot = makePart(
		"Plot",
		CONFIG.PlotSize,
		CONFIG.PlotColor,
		origin * CFrame.new(0, CONFIG.PlotSize.Y * 0.5, 0),
		base
	)
	plot.Material = Enum.Material.Slate
	base.PrimaryPart = plot

	-- A thin lip around the plot edge. Cheap, but it stops the base reading as
	-- a floating grey rectangle on a grey baseplate.
	local trim = makePart(
		"PlotTrim",
		CONFIG.PlotSize + Vector3.new(1.6, -0.6, 1.6),
		CONFIG.TrimColor,
		origin * CFrame.new(0, CONFIG.PlotSize.Y * 0.35, 0),
		base
	)
	trim.Material = Enum.Material.Wood

	local dojo = dojoTemplate:Clone()
	dojo.Name = "Dojo"
	dojo:PivotTo(
		origin * CFrame.new(CONFIG.DojoOffsetX, plotTop + metrics.dojoPivotToBottom, 0)
	)
	dojo.Parent = base

	local bag = bagTemplate:Clone()
	bag.Name = "Punchingbag"
	bag:PivotTo(origin * CFrame.new(
		CONFIG.DojoOffsetX,
		interiorFloorY() + metrics.bagPivotToBottom,
		CONFIG.BagOffsetZ
	))
	bag.Parent = base

	buildPit(base, origin)
	buildBagPost(base, origin)
	buildSign(player, base, origin)

	base.Parent = basesFolder
	return base
end

local function destroyBase(player: Player)
	local base = bases[player]
	if base then
		bases[player] = nil
		base:Destroy()
	end
end

local function ensureBase(player: Player): Model?
	local existing = bases[player]
	if existing and existing.Parent then
		return existing
	end

	local slot = claimSlot(player)
	if not slot then
		-- Servers are capped well below MaxSlots, so this means a leak in slot
		-- release rather than a legitimately full world. Say so loudly.
		warn(`[MiniBaseService] no free base slot for {player.Name}`)
		return nil
	end

	local base = buildBase(player, slot)
	bases[player] = base

	-- Services that own behaviour on the furniture (the tower prompt, the
	-- upgrade prompt) hook themselves up here rather than the base service
	-- knowing what any of its props are for.
	MiniBaseService.BaseCreated:Fire(player, base)

	if GameConfig.DebugLogging then
		print(`[MiniBaseService] Mini Base created for {player.Name} in slot {slot}`)
	end

	if AnalyticsService then
		AnalyticsService.trackOnce(player, "MiniBaseCreated", { slot = slot })
	end

	return base
end

-- Put the player on their own plot, outside the dojo opening looking in.
--
-- Roblox finishes its own SpawnLocation placement AFTER CharacterAdded fires,
-- so a single pivot here is silently overwritten and the player ends up back at
-- the world spawn. We re-assert until it sticks, then stop.
local function placePlayerAtBase(player: Player, character: Model)
	local base = bases[player]
	if not base then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if not root then
		return
	end

	local origin = slotCFrame(base:GetAttribute("Slot"))
	local target = origin * CFrame.new(
		CONFIG.DojoOffsetX,
		CONFIG.PlotSize.Y + 3,
		CONFIG.PlayerSpawnOffsetZ
	)
	-- Face into the dojo, so the first thing on screen is the thing that matters.
	local lookAt = (origin * CFrame.new(
		CONFIG.DojoOffsetX,
		CONFIG.PlotSize.Y + 3,
		CONFIG.BagOffsetZ
	)).Position
	local facing = CFrame.lookAt(target.Position, lookAt)

	for attempt = 1, 6 do
		if character.Parent == nil then
			return
		end

		character:PivotTo(facing)
		task.wait(0.1)

		-- Generous radius: the player may start walking immediately. We only
		-- care that the engine did not yank them back to world spawn.
		if (root.Position - target.Position).Magnitude < 15 then
			if GameConfig.DebugLogging and attempt > 1 then
				print(`[MiniBaseService] {player.Name} placed at base after {attempt} attempts`)
			end
			return
		end
	end

	warn(`[MiniBaseService] could not keep {player.Name} at their base`)
end

local function onPlayerAdded(player: Player)
	ensureBase(player)

	player.CharacterAdded:Connect(function(character)
		task.spawn(placePlayerAtBase, player, character)
	end)

	if player.Character then
		task.spawn(placePlayerAtBase, player, player.Character)
	end
end

--[[ Public API — used from V0.4B onward ]]

function MiniBaseService.getBase(player: Player): Model?
	return bases[player]
end

-- Where the Mini stands to train: on the dojo floor, in front of the bag,
-- facing it. Derived from the same measurements as the bag placement so the
-- two cannot drift apart when the layout is tuned.
-- `reach` is the Mini's current size relative to base scale. A Mini that has
-- grown has longer arms, so it has to stand proportionally further back or its
-- fist ends up inside the bag.
function MiniBaseService.getTrainingCFrame(player: Player, reach: number?): CFrame?
	local base = bases[player]
	if not base then
		return nil
	end

	local origin = slotCFrame(base:GetAttribute("Slot"))
	local floorY = interiorFloorY()

	-- Aim at the part the punch is supposed to land on. Falling back to the
	-- authored offset keeps the Mini training rather than standing idle if the
	-- bag model is ever re-exported without a recognisable body part.
	local body = MiniBaseService.getBagBody(player)
	local target = body
		and Vector3.new(body.Position.X, floorY, body.Position.Z)
		or (origin * CFrame.new(CONFIG.DojoOffsetX, floorY, CONFIG.BagOffsetZ)).Position

	local spot = target - Vector3.new(0, 0, CONFIG.StandOffFromBagZ * (reach or 1))

	return CFrame.lookAt(spot, target)
end

-- Where the Mini stands to fight, and where its opponent stands facing it. Both
-- derived from the same pit so a re-tuned layout moves them together.
function MiniBaseService.getPitSpots(player: Player, reach: number?): (CFrame?, CFrame?)
	local base = bases[player]
	if not base then
		return nil, nil
	end

	local origin = slotCFrame(base:GetAttribute("Slot"))
	local floorY = CONFIG.PlotSize.Y + 0.4
	-- Same rule as the bag: a bigger fighter squares up from further away.
	local gap = CONFIG.PitRadius * 0.45 * (reach or 1)

	local fighter = (origin * CFrame.new(CONFIG.PitOffsetX, floorY, -gap)).Position
	local enemy = (origin * CFrame.new(CONFIG.PitOffsetX, floorY, gap)).Position

	return CFrame.lookAt(fighter, enemy), CFrame.lookAt(enemy, fighter)
end

function MiniBaseService.getBagModel(player: Player): Model?
	local base = bases[player]
	return base and base:FindFirstChild("Punchingbag") or nil
end

-- The part a punch should visibly react against, for V0.4C.
function MiniBaseService.getBagBody(player: Player): BasePart?
	local bag = MiniBaseService.getBagModel(player)
	if not bag then
		return nil
	end
	for _, descendant in bag:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name:lower():find("bagbody") then
			return descendant
		end
	end
	return nil
end

function MiniBaseService.Init(registry)
	AnalyticsService = registry.AnalyticsService

	local assets = ServerStorage:FindFirstChild("Assets")
	-- Failing loudly here beats building twenty invisible bases and wondering
	-- why the world looks empty.
	assert(assets, "ServerStorage.Assets is missing — the Dojo and Punchingbag models must live there")

	local dojoSource = assets:FindFirstChild("Dojo")
	local bagSource = assets:FindFirstChild("Punchingbag")
	assert(dojoSource, "ServerStorage.Assets.Dojo is missing")
	assert(bagSource, "ServerStorage.Assets.Punchingbag is missing")

	-- Shrink working copies rather than the stored assets, so the originals stay
	-- at authored scale and remain editable in Studio.
	dojoTemplate = dojoSource:Clone()
	dojoTemplate:ScaleTo(MINI_SCALE)

	bagTemplate = bagSource:Clone()
	bagTemplate:ScaleTo(MINI_SCALE)

	-- Measured AFTER scaling, so every downstream placement is already in
	-- Mini units and no call site has to remember to convert.
	measureTemplates()

	if GameConfig.DebugLogging then
		print(string.format(
			"[MiniBaseService] templates measured: dojo height %.2f, interior floor Y %.2f, bag lift %.2f",
			metrics.dojoHeight, interiorFloorY(), metrics.bagPivotToBottom))
	end

	local existing = Workspace:FindFirstChild("MiniBases")
	if existing and existing:IsA("Folder") then
		basesFolder = existing
		basesFolder:ClearAllChildren()
	else
		if existing then
			existing:Destroy()
		end
		basesFolder = Instance.new("Folder")
		basesFolder.Name = "MiniBases"
		basesFolder.Parent = Workspace
	end
end

function MiniBaseService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player)
		destroyBase(player)
		releaseSlot(player)
	end)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MiniBaseService
