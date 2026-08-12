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
	-- "everyone has their own place" the moment you look around. Each player
	-- gets their OWN dojo and their OWN Colyseum -- but they all stand in the
	-- same world, because half the point is watching what everybody else's Mini
	-- is turning into.
	Origin = Vector3.new(0, 0, 90),
	-- Wide enough to clear the 57-stud arena plate with a gap to walk down, and
	-- deep enough to clear the whole dojo-bridge-arena run.
	SlotSpacing = 72,
	RowSpacing = 130,
	SlotsPerRow = 5,
	MaxSlots = 20,

	-- The plot itself is the authored map in ServerStorage.Assets.BaseMap:
	-- DojoSpace, Bridge, ArenaPlate, laid out along +Z. Nothing about its shape
	-- is hardcoded here -- everything below is measured off the clone, so the
	-- map can be re-edited in Studio without touching this file.

	-- How wide the Colyseum is built, across its outer wall, as a FRACTION of
	-- the arena plate it stands on. The model is authored as a full-size
	-- stadium; what matters is that it sits comfortably on its plate.
	ArenaPlateFraction = 0.82,
	-- Fallback only, for a place whose Arena asset is missing: the old bare ring
	-- kept the loop playable rather than leaving the Mini nowhere to fight.
	PitRadius = 2.4,

	-- How far apart the two fighters square up, in MINI lengths. Deliberately
	-- NOT derived from the arena's size: the arena got twenty times bigger and
	-- the fighters did not, and a gap scaled off the building would leave them
	-- swinging at each other from across the sand.
	FightGapStuds = 1.1,


	-- The dojo model is open on its -Z face, so everything the Mini should be
	-- seen doing is arranged along that axis. These offsets are authored
	-- against the full-size model and shrink with it.
	BagOffsetZ = 4.0 * MINI_SCALE,
	-- How far in front of the BAG BODY the Mini stands to punch it. Measured
	-- against the bag itself rather than the stand, because the bag hangs off
	-- one side of its frame and a Mini aimed at the frame punches thin air.
	-- Tuned by measuring the Mini's actual reach at full extension against the
	-- bag's radius in-game: close enough that the fist presses into the bag.
	StandOffFromBagZ = 1.70 * MINI_SCALE,

	-- The player is NOT scaled, so the sign height is in player units.
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
-- The authored level: DojoSpace, Bridge, ArenaPlate. Laid out in Studio, cloned
-- once per player, and never reasoned about by hardcoded offsets -- every
-- placement below measures the clone instead.
local mapTemplate: Model
-- Optional: a place without it falls back to the bare pit, so a missing art
-- asset degrades the look rather than breaking the loop.
local arenaTemplate: Model?

-- Measured from the templates at boot. See the header for why.
local metrics = {
	dojoPivotToBottom = 0,
	dojoFloorTopFromPivot = 0,
	dojoHeight = 0,
	dojoFootprint = 0,
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

	return CFrame.new(CONFIG.Origin + Vector3.new(xOffset, 0, row * CONFIG.RowSpacing))
end

-- The authored map runs dojo -> bridge -> arena along +Z. Everything that needs
-- to know where something is asks these rather than doing arithmetic on offsets,
-- so the map can be moved around in Studio and the game follows it.
local function mapPart(base: Model, name: string): BasePart?
	local part = base:FindFirstChild(name)
	return part and part:IsA("BasePart") and part or nil
end

-- Y of the surface a given platform's contents stand on.
local function surfaceY(part: BasePart): number
	return part.Position.Y + part.Size.Y * 0.5
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
	metrics.dojoFootprint = math.max(dojoSize.X, dojoSize.Z)

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

-- How far the dojo's walkable interior floor sits above whatever the model is
-- standing on. The Mini and the bag stand on THAT, not on the model's lowest
-- point, or both sink into the floorboards.
local function interiorFloorLift(): number
	return metrics.dojoPivotToBottom + metrics.dojoFloorTopFromPivot
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

-- Where the arena's sand actually is, and how much of it is flat enough to
-- fight on. Both are MEASURED off the built model rather than derived from the
-- bounding box, because the model is a stadium: most of its height is seating,
-- and its floor sits well above its base. Probing outward from the middle finds
-- the point where the sand stops and the terracing begins.
local function measureArenaFloor(arena: Model): (number?, number?)
	local box, size = arena:GetBoundingBox()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { arena }

	local function probe(offset: number): number?
		local from = box.Position
			+ Vector3.new(offset, size.Y, 0)
		local hit = Workspace:Raycast(from, Vector3.new(0, size.Y * 2, 0) * -1, params)

		return hit and hit.Position.Y or nil
	end

	local floorY = probe(0)

	if not floorY then
		return nil, nil
	end

	-- Walk outward in small steps until the ground stops being the floor. The
	-- last step that was still level is the usable radius.
	local limit = size.X * 0.5
	local step = limit / 24
	local radius = step

	for offset = step, limit, step do
		local y = probe(offset)

		if not y or math.abs(y - floorY) > 0.02 * size.Y then
			break
		end

		radius = offset
	end

	return floorY, radius
end

-- The Colyseum. Where strength is MEASURED, as against the dojo where it is
-- made. It stands on the same plot as the dojo rather than in a separate world:
-- the player has to be able to watch the Mini walk from the bag to the fight and
-- back without moving the camera.
local function buildArena(base: Model, plate: BasePart): boolean
	if not arenaTemplate then
		return false
	end

	local arena = arenaTemplate:Clone()
	arena.Name = "Arena"

	local _, templateSize = arenaTemplate:GetBoundingBox()

	-- Model:ScaleTo is ABSOLUTE against the model's authored size, not relative
	-- to how big it is right now. This asset was saved already scaled up, so
	-- passing the ratio straight in shrinks it to a third of the intended size.
	-- Multiply through the current scale instead.
	arena:ScaleTo(
		arenaTemplate:GetScale()
		* math.min(plate.Size.X, plate.Size.Z)
		* CONFIG.ArenaPlateFraction
		/ math.max(templateSize.X, templateSize.Z)
	)

	-- The asset is unanchored, and an unanchored stadium falls through the plot
	-- the moment the game starts.
	for _, descendant in arena:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	-- Stand it in the middle of its plate, bounding-box bottom flush with the
	-- surface.
	local box, size = arena:GetBoundingBox()
	local pivotToBottom = arena:GetPivot().Position.Y - (box.Position.Y - size.Y * 0.5)

	arena:PivotTo(CFrame.new(
		plate.Position.X,
		surfaceY(plate) + pivotToBottom,
		plate.Position.Z
	))
	arena.Parent = base

	-- Measured after placing, so the numbers are in world space and survive the
	-- model being re-exported with different proportions.
	local floorY, radius = measureArenaFloor(arena)

	if not floorY or not radius then
		warn("[MiniBaseService] could not find the arena floor; falling back to the bare pit")
		arena:Destroy()
		return false
	end

	-- The model is one solid bowl with no doorway cut into it, so a physical
	-- fighter can neither walk onto its sand nor off it again. Ramps and raised
	-- floors were tried and every one of them had an edge the Mini caught on.
	--
	-- The simple answer is to stop making it climb: sink the building until its
	-- sand is FLUSH with the plate, and let the seating rise around it. Then the
	-- arena floor is just the ground, the Mini walks straight in across the
	-- flat, and the mesh is pure scenery -- non-colliding, so the stands cannot
	-- block it either. No ramp, no plinth, no lip to trip over.
	local plateTop = surfaceY(plate)
	local drop = floorY - plateTop

	arena:PivotTo(arena:GetPivot() - Vector3.new(0, drop, 0))
	floorY = plateTop

	for _, descendant in arena:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end

	arena:SetAttribute("FloorY", floorY)
	arena:SetAttribute("FloorRadius", radius)

	if GameConfig.DebugLogging then
		print(string.format(
			"[MiniBaseService] arena scaled %.3f, floor Y %.2f, fighting radius %.2f",
			arena:GetScale(), floorY, radius
		))
	end

	return true
end

-- Fallback for a place with no Arena asset: a bare ring, which is what the game
-- fought in before the Colyseum existed. Keeps the loop playable.
local function buildPit(base: Model, origin: CFrame)
	local floor = makePart(
		"Pit",
		Vector3.new(CONFIG.PitRadius * 2, 0.4, CONFIG.PitRadius * 2),
		Color3.fromRGB(122, 48, 46),
		origin * CFrame.new(0, 1.2, 0),
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
		origin * CFrame.new(0, 1.08, 0),
		base
	)
	rim.Shape = Enum.PartType.Cylinder
	rim.CFrame = rim.CFrame * CFrame.Angles(0, 0, math.rad(90))
end

-- The post the player walks up to and presses. TowerService fills in the text
-- and does the work; the base only owns the furniture. Stands outside whatever
-- the Mini fights in, so it is reachable with either arena or fallback pit.
local function buildTowerPost(
	base: Model,
	dojoSpace: BasePart,
	bridge: BasePart?,
	plate: BasePart?
)
	-- At the dojo end of the bridge, not out at the arena. The player presses
	-- this while standing over their training Mini, and the Mini then makes the
	-- walk -- which is the trip that sells the whole loop.
	local anchor = bridge or plate or dojoSpace
	local z = if bridge
		then bridge.Position.Z - bridge.Size.Z * 0.5 + 2.5
		else anchor.Position.Z

	local post = makePart(
		"TowerPost",
		Vector3.new(0.8, 3.2, 0.8),
		Color3.fromRGB(38, 40, 48),
		CFrame.new(
			anchor.Position.X + anchor.Size.X * 0.5 - 1.5,
			surfaceY(anchor) + 1.6,
			z
		),
		base
	)
	post.Material = Enum.Material.Metal

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TowerPrompt"
	prompt.ObjectText = "COLYSEUM"
	prompt.ActionText = "SEND MINI"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = post
end

-- Where the coins go. Stands beside the dojo opening so the upgrade is read in
-- the same glance as the thing it upgrades.
local function buildBagPost(base: Model, dojoSpace: BasePart, dojo: Model)
	local post = makePart(
		"BagPost",
		Vector3.new(0.8, 3.0, 0.8),
		Color3.fromRGB(196, 148, 100),
		CFrame.new(
			dojoSpace.Position.X - dojoSpace.Size.X * 0.5 + 2.0,
			surfaceY(dojoSpace) + 1.5,
			dojo:GetPivot().Position.Z
		),
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

local function buildSign(player: Player, base: Model, dojoSpace: BasePart)
	local anchor = makePart(
		"SignAnchor",
		Vector3.new(0.6, 0.6, 0.6),
		Color3.fromRGB(30, 32, 38),
		CFrame.new(
			dojoSpace.Position.X,
			surfaceY(dojoSpace) + metrics.dojoHeight + CONFIG.SignClearance,
			dojoSpace.Position.Z - dojoSpace.Size.Z * 0.5 - 1.0
		),
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

	-- The plot is the authored map, cloned. Its three platforms are the whole
	-- geography of the game: the Mini trains at one end, walks the bridge, and
	-- fights at the other. Laid out in Studio rather than in code, because a
	-- level is something you look at while you move it.
	local base = mapTemplate:Clone()
	base.Name = `MiniBase_{player.UserId}`
	base:SetAttribute("OwnerUserId", player.UserId)
	base:SetAttribute("Slot", slot)

	-- Anchored on the dojo end, so slot origin means "where this player's dojo
	-- is" and the arena trails off behind it.
	local dojoSpace = mapPart(base, "DojoSpace")
	assert(dojoSpace, "BaseMap is missing its DojoSpace part")

	base:PivotTo(origin * base:GetPivot():ToObjectSpace(dojoSpace.CFrame):Inverse())

	-- Parented before the props go on, because the arena MEASURES itself with a
	-- raycast and nothing outside Workspace can be hit by one.
	base.Parent = basesFolder

	local bridge = mapPart(base, "Bridge")
	local plate = mapPart(base, "ArenaPlate")
	local dojoTop = surfaceY(dojoSpace)

	-- The dojo sits at the back of its own space, so the Mini has the floor in
	-- front of it to walk around on and the player has somewhere to stand.
	-- Turned to face the bridge. The model is open on ONE side, and that opening
	-- has to point at the rest of the map: a Mini sent to the Colyseum walks out
	-- of it in a straight line. Facing the other way, the fighter's route led
	-- through the back wall -- which the old hand-written movement simply slid
	-- through, and a physical body cannot.
	local dojo = dojoTemplate:Clone()
	dojo.Name = "Dojo"
	dojo:PivotTo(
		CFrame.new(
			dojoSpace.Position.X,
			dojoTop + metrics.dojoPivotToBottom,
			dojoSpace.Position.Z - dojoSpace.Size.Z * 0.5 + metrics.dojoFootprint * 0.5 + 1.0
		)
		* CFrame.Angles(0, math.pi, 0)
	)
	-- The dojo is a knee-high toy set, and its walls are scenery. Pathfinding
	-- does not put these mesh walls into its navmesh, so it happily plans routes
	-- through them -- and a physical Mini then walks into one and stops dead.
	-- Rather than fight that, only the FLOOR collides. The Mini stands on the
	-- mat and can always get to the doorway; nothing can wedge it in a corner of
	-- a building four studs wide.
	for _, descendant in dojo:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = descendant.Name:lower():find("floor") ~= nil
		end
	end

	dojo.Parent = base

	local bag = bagTemplate:Clone()
	bag.Name = "Punchingbag"
	bag:PivotTo(CFrame.new(
		dojo:GetPivot().Position.X,
		dojoTop + interiorFloorLift() + metrics.bagPivotToBottom,
		-- At the CLOSED end, so the Mini punches with its back to the doorway.
		dojo:GetPivot().Position.Z - CONFIG.BagOffsetZ
	))
	bag.Parent = base

	-- How much room the Mini has to roam when it has nothing to do: the WHOLE
	-- dojo platform, not the little mat inside the dojo model. Published on the
	-- base because it is the client that walks the Mini around -- presentation,
	-- not state.
	base:SetAttribute("WanderCenter", Vector3.new(
		dojoSpace.Position.X,
		dojoTop,
		dojoSpace.Position.Z
	))
	base:SetAttribute("WanderExtents", Vector2.new(
		math.max(0.5, dojoSpace.Size.X * 0.5 - 1.5),
		math.max(0.5, dojoSpace.Size.Z * 0.5 - 1.5)
	))

	if plate and not buildArena(base, plate) then
		buildPit(base, CFrame.new(plate.Position.X, 0, plate.Position.Z))
	end

	buildTowerPost(base, dojoSpace, bridge, plate)
	buildBagPost(base, dojoSpace, dojo)
	buildSign(player, base, dojoSpace)

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

	local dojoSpace = mapPart(base, "DojoSpace")
	if not dojoSpace then
		return
	end

	-- Beside the dojo's OPEN face, not behind it.
	--
	-- The Mini spawns next to its owner, and the dojo is a closed box with one
	-- doorway. Landing the player behind the back wall put the Mini there too,
	-- with no way in: it walked into the wall and stayed there. Standing them
	-- off to the side of the opening means the Mini's first walk is straight
	-- through the door, and the player is looking into the dojo with the bridge
	-- and the Colyseum stretching away behind it.
	local dojo = base:FindFirstChild("Dojo")
	local standY = surfaceY(dojoSpace) + 3
	local dojoZ = if dojo then dojo:GetPivot().Position.Z else dojoSpace.Position.Z
	local lookAt = Vector3.new(dojoSpace.Position.X, standY, dojoZ)

	local target = CFrame.new(
		dojoSpace.Position.X - dojoSpace.Size.X * 0.5 + 3.0,
		standY,
		dojoZ + metrics.dojoFootprint * 0.9
	)
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

	local dojo = base:FindFirstChild("Dojo")
	local dojoSpace = mapPart(base, "DojoSpace")

	if not dojo or not dojoSpace then
		return nil
	end

	local floorY = surfaceY(dojoSpace) + interiorFloorLift()

	-- Aim at the part the punch is supposed to land on. Falling back to the
	-- authored offset keeps the Mini training rather than standing idle if the
	-- bag model is ever re-exported without a recognisable body part.
	local body = MiniBaseService.getBagBody(player)
	local target = body
		and Vector3.new(body.Position.X, floorY, body.Position.Z)
		or (dojo:GetPivot().Position - Vector3.new(0, 0, CONFIG.BagOffsetZ))

	-- Stood on the doorway side of the bag, facing into the dojo. Walking away
	-- afterwards is then a straight line out and down the bridge.
	local spot = target + Vector3.new(0, 0, CONFIG.StandOffFromBagZ * (reach or 1))

	return CFrame.lookAt(spot, target)
end

-- Where the Mini stands to fight, and where its opponent stands facing it. Both
-- derived from the same pit so a re-tuned layout moves them together.
function MiniBaseService.getPitSpots(player: Player, reach: number?): (CFrame?, CFrame?)
	local base = bases[player]
	if not base then
		return nil, nil
	end

	local plate = mapPart(base, "ArenaPlate")

	-- The arena's sand is well above its plate -- measured when it was built.
	-- The bare fallback pit has no such attribute, so it keeps a flat number.
	local arena = base:FindFirstChild("Arena")
	local floorY = arena and arena:GetAttribute("FloorY")
	local centre = if arena
		then arena:GetPivot().Position
		else (plate and plate.Position or Vector3.zero)

	if type(floorY) ~= "number" then
		floorY = plate and (surfaceY(plate) + 0.4) or 1.4
	end

	-- A bigger fighter squares up from further away -- but the distance is in
	-- MINI lengths, not arena lengths. See CONFIG.FightGapStuds.
	local gap = CONFIG.FightGapStuds * (reach or 1)

	local fighter = Vector3.new(centre.X, floorY, centre.Z - gap)
	local enemy = Vector3.new(centre.X, floorY, centre.Z + gap)

	return CFrame.lookAt(fighter, enemy), CFrame.lookAt(enemy, fighter)
end

-- Where a Mini heading INTO the Colyseum should walk to first: on the plate,
-- just outside the building, on the side the bridge arrives from.
--
-- The arena model is a closed bowl -- its seating has no doorway, so nothing can
-- path onto the sand. Rather than pretend otherwise, callers path to here and
-- cover the last stretch in a straight line. Returns nil when the destination is
-- not inside the arena, so ordinary walks are unaffected.
function MiniBaseService.getArenaApproach(player: Player, destination: Vector3): Vector3?
	local base = bases[player]
	local arena = base and base:FindFirstChild("Arena")
	local plate = base and mapPart(base, "ArenaPlate")

	if not arena or not plate then
		return nil
	end

	local _, size = arena:GetBoundingBox()
	local centre = arena:GetPivot().Position
	local flat = Vector3.new(destination.X - centre.X, 0, destination.Z - centre.Z)
	local outerRadius = math.max(size.X, size.Z) * 0.5

	if flat.Magnitude > outerRadius then
		return nil
	end

	-- A stride clear of the outer wall, on the bridge side (-Z).
	return Vector3.new(
		centre.X,
		surfaceY(plate) + 0.5,
		centre.Z - outerRadius - 2.0
	)
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

	-- The Colyseum is authored as a full-size stadium rather than at Mini scale,
	-- so it is scaled per base against its own measured footprint instead of by
	-- MINI_SCALE. Optional on purpose: see arenaTemplate.
	local mapSource = assets:FindFirstChild("BaseMap")
	assert(mapSource, "ServerStorage.Assets.BaseMap is missing — the authored DojoSpace/Bridge/ArenaPlate layout must live there")
	mapTemplate = mapSource:Clone()

	local arenaSource = assets:FindFirstChild("Arena")

	if arenaSource and arenaSource:IsA("Model") then
		arenaTemplate = arenaSource:Clone()
	else
		warn("[MiniBaseService] ServerStorage.Assets.Arena is missing — using the bare pit")
	end

	-- Measured AFTER scaling, so every downstream placement is already in
	-- Mini units and no call site has to remember to convert.
	measureTemplates()

	if GameConfig.DebugLogging then
		print(string.format(
			"[MiniBaseService] templates measured: dojo height %.2f, interior floor Y %.2f, bag lift %.2f",
			metrics.dojoHeight, interiorFloorLift(), metrics.bagPivotToBottom))
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
