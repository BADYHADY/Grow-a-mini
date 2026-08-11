--!nonstrict
-- Turns a standard R6 character into the chibi proportions a Mini uses.
--
-- We scale each body part by a DIFFERENT factor -- oversized head, stubby limbs
-- -- which is what makes the Mini read as a collectible figurine rather than a
-- shrunken player. Uniform scaling looks like a bug; this looks designed.
--
-- Everything else in this file exists because non-uniform scaling breaks a rig
-- in three separate ways if you only touch Part.Size:
--
--   1. Motor6D offsets are in stud space, so limbs detach or overlap.
--      A joint's C0 belongs to Part0 and scales with Part0; C1 belongs to Part1.
--   2. Attachment positions are in stud space, so hats float or sink.
--   3. SpecialMesh ignores Part.Size for rendering, so the head mesh stays big
--      while its collision box shrinks.
--
-- Those three are exactly the "hair clips through head / accessory floats in
-- the air" failure modes the Mini has to avoid.

local RigScaler = {}

local function rotationOnly(cf: CFrame): CFrame
	return cf - cf.Position
end

local function scaleCFrame(cf: CFrame, scale: Vector3): CFrame
	return CFrame.new(cf.Position * scale) * rotationOnly(cf)
end

-- Scales whatever drives this part's visual size. MeshParts render from Size;
-- SpecialMesh renders from Scale and ignores Size entirely.
local function scaleVisual(part: BasePart, scale: Vector3)
	local specialMesh = part:FindFirstChildOfClass("SpecialMesh")
	if specialMesh then
		specialMesh.Scale *= scale
	end
	part.Size *= scale
end

local function scaleAttachments(part: BasePart, scale: Vector3)
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			child.CFrame = scaleCFrame(child.CFrame, scale)
		end
	end
end

-- Accessories are welded by a hard Weld whose offsets were baked from the
-- attachment pair at build time. Scaling the parts invalidates those offsets,
-- so we rebuild the weld from the (already scaled) attachments instead of
-- trying to patch the old numbers.
local function reattachAccessory(accessory: Accessory, scaleOfBodyPart: (BasePart) -> Vector3)
	local handle = accessory:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return
	end

	local handleAttachment: Attachment? = nil
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") then
			handleAttachment = child
			break
		end
	end
	if not handleAttachment then
		return
	end

	-- The body-side attachment shares the accessory attachment's name. It has
	-- already been scaled, since body parts are processed before accessories.
	local weld = handle:FindFirstChildOfClass("Weld")
	local bodyPart = weld and (weld.Part0 == handle and weld.Part1 or weld.Part0) :: BasePart?
	if not bodyPart then
		return
	end

	local bodyAttachment = bodyPart:FindFirstChild(handleAttachment.Name) :: Attachment?
	if not bodyAttachment then
		return
	end

	-- An accessory should shrink with whatever it sits on: a hat follows the
	-- head's scale, a backpack the torso's.
	local scale = scaleOfBodyPart(bodyPart)
	scaleVisual(handle, scale)
	handleAttachment.CFrame = scaleCFrame(handleAttachment.CFrame, scale)

	weld.Part0 = bodyPart
	weld.C0 = bodyAttachment.CFrame
	weld.Part1 = handle
	weld.C1 = handleAttachment.CFrame
end

-- `scales` maps body part name -> per-axis scale factor. Parts not listed are
-- left alone, which is what we want for anything we did not anticipate.
function RigScaler.apply(model: Model, scales: { [string]: Vector3 })
	local function scaleOf(part: BasePart): Vector3
		return scales[part.Name] or Vector3.one
	end

	-- Pass 1: joints. Read every Motor6D BEFORE resizing anything, because the
	-- offsets we are scaling are relative to the original sizes.
	local joints: { { motor: Motor6D, c0: Vector3, c1: Vector3 } } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part0 and descendant.Part1 then
			table.insert(joints, {
				motor = descendant,
				c0 = scaleOf(descendant.Part0),
				c1 = scaleOf(descendant.Part1),
			})
		end
	end

	-- Pass 2: body parts.
	for name, scale in scales do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			scaleAttachments(part, scale)
			scaleVisual(part, scale)
		end
	end

	-- Pass 3: apply the joint offsets we captured.
	for _, joint in joints do
		joint.motor.C0 = scaleCFrame(joint.motor.C0, joint.c0)
		joint.motor.C1 = scaleCFrame(joint.motor.C1, joint.c1)
	end

	-- Pass 4: accessories, last, so the body attachments they weld to are final.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Accessory") then
			reattachAccessory(descendant, scaleOf)
		end
	end
end

-- Builds the scale map for an R6 rig from the MiniConfig.Scale block.
function RigScaler.chibiScales(config: {
	Overall: number,
	Head: number,
	Torso: number,
	Arm: number,
	Leg: number,
	HandWidthBoost: number,
}): { [string]: Vector3 }
	local overall = config.Overall

	local head = Vector3.one * (overall * config.Head)
	local torso = Vector3.one * (overall * config.Torso)

	-- Widening the whole limb rather than just the wrist: R6 has no forearm to
	-- taper, and a uniformly chunky arm reads as "stubby toy" at this size,
	-- which is the look we are after.
	local arm = Vector3.new(
		overall * config.Arm * config.HandWidthBoost,
		overall * config.Arm,
		overall * config.Arm * config.HandWidthBoost
	)
	local leg = Vector3.new(overall * config.Leg, overall * config.Leg, overall * config.Leg)

	return {
		Head = head,
		Torso = torso,
		-- The root drives collision and movement, so it tracks the torso.
		HumanoidRootPart = torso,
		["Left Arm"] = arm,
		["Right Arm"] = arm,
		["Left Leg"] = leg,
		["Right Leg"] = leg,
	}
end

return RigScaler
