--!strict
-- A serializable description of one Mini: how it looks and how strong it is.
--
-- Why this exists in step 1.1 rather than later: three separate features need
-- it, and all three are impossible to add retroactively for existing players.
--   1. Day 1 vs Day 30 comparison (needs the level-1 snapshot).
--   2. Defend & Challenge async duels (needs an offline player's build).
--   3. Inspecting another player's Mini without loading their live character.
--
-- Appearance is stored as raw asset ids and colour values rather than as a
-- HumanoidDescription, because a HumanoidDescription is an Instance and cannot
-- be written to a DataStore, and because we want the snapshot to survive the
-- player changing their avatar afterwards.

export type Appearance = {
	-- Classic clothing texture ids. 0 means none.
	ShirtId: number,
	PantsId: number,
	FaceId: number,
	-- Accessory asset ids, already trimmed to MiniConfig.Appearance.MaxAccessories.
	AccessoryIds: { number },
	-- Body colours as packed RGB integers (Color3:ToHex is a string; an integer
	-- is smaller in the DataStore and cheaper to compare).
	HeadColor: number,
	TorsoColor: number,
	LeftArmColor: number,
	RightArmColor: number,
	LeftLegColor: number,
	RightLegColor: number,
}

export type Stats = {
	Damage: number,
	AttacksPerSecond: number,
	CritChance: number,
	CritMultiplier: number,
	Health: number,
}

export type Snapshot = {
	-- Bumped independently of the profile schema, since snapshots are also
	-- passed over the network and cached in MemoryStore later.
	Version: number,
	UserId: number,
	DisplayName: string,
	CapturedUnix: number,
	Level: number,
	Mutations: { string },
	Appearance: Appearance,
	Stats: Stats,
}

local MiniSnapshot = {}

MiniSnapshot.CURRENT_VERSION = 1

-- A neutral Mini used when a player's avatar cannot be fetched. Never blocks a
-- spawn: we show this immediately and swap in the real appearance when it lands.
function MiniSnapshot.blankAppearance(): Appearance
	local grey = 0x9C9C9C
	return {
		ShirtId = 0,
		PantsId = 0,
		FaceId = 0,
		AccessoryIds = {},
		HeadColor = grey,
		TorsoColor = grey,
		LeftArmColor = grey,
		RightArmColor = grey,
		LeftLegColor = grey,
		RightLegColor = grey,
	}
end

function MiniSnapshot.toColor3(packed: number): Color3
	return Color3.fromRGB(bit32.band(bit32.rshift(packed, 16), 0xFF), bit32.band(bit32.rshift(packed, 8), 0xFF), bit32.band(packed, 0xFF))
end

function MiniSnapshot.fromColor3(color: Color3): number
	local r = math.round(color.R * 255)
	local g = math.round(color.G * 255)
	local b = math.round(color.B * 255)
	return bit32.bor(bit32.lshift(r, 16), bit32.lshift(g, 8), b)
end

return MiniSnapshot
