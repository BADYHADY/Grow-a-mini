--!strict
-- Mutations. The single most important rule in this file:
--
--   A mutation must be readable at 50 studs, in greyscale, on a phone.
--
-- Every Mini already looks different, because it is a different person's avatar.
-- That means colour alone can never signal rarity -- it drowns in avatar noise.
-- Mutations must therefore change SILHOUETTE, SCALE, MATERIAL or add an AURA.
-- If a proposed mutation only recolours something, it is not a mutation.

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Secret"

export type VisualProfile = {
	-- Multiplies the Mini's overall scale. This is the strongest readability
	-- lever we have, so the rare tiers lean on it hard.
	ScaleMultiplier: number,
	-- Overrides the material of every body part. nil keeps the avatar's look.
	BodyMaterial: Enum.Material?,
	-- Named aura effect, resolved by VfxController. nil means no aura.
	Aura: string?,
	-- Named trail effect left while moving.
	Trail: string?,
	-- Adds a silhouette-changing attachment set (horns, wings, plating).
	SilhouettePart: string?,
	-- Colour tint applied over the body. Support only, never the sole signal.
	Tint: Color3?,
}

export type Mutation = {
	Id: string,
	DisplayName: string,
	Rarity: Rarity,
	-- Relative weight inside the roll table. Odds are derived from these and
	-- must be shown to the player -- see the note at the bottom of this file.
	Weight: number,
	-- Additive stat modifiers, applied after upgrades.
	StatModifiers: {
		DamageMultiplier: number?,
		AttackSpeedMultiplier: number?,
		CritChanceBonus: number?,
		HealthMultiplier: number?,
	},
	Visual: VisualProfile,
	-- Fires a server-wide announcement when rolled. Reserve for genuinely rare
	-- results, capped by the announcement rate limiter, or it becomes spam.
	AnnounceServerWide: boolean,
}

local Mutations: { [string]: Mutation } = {
	-- MVP set: three mutations, one per readability mechanism, so we can prove
	-- the "readable at 50 studs" rule works before authoring twenty more.

	GiantFists = {
		Id = "GiantFists",
		DisplayName = "Giant Fists",
		Rarity = "Common",
		Weight = 600,
		StatModifiers = { DamageMultiplier = 1.15 },
		Visual = {
			ScaleMultiplier = 1.0,
			SilhouettePart = "GiantFists", -- oversized hands, reads as a silhouette change
		},
		AnnounceServerWide = false,
	},

	Ember = {
		Id = "Ember",
		DisplayName = "Ember",
		Rarity = "Uncommon",
		Weight = 300,
		StatModifiers = { DamageMultiplier = 1.1, AttackSpeedMultiplier = 1.08 },
		Visual = {
			ScaleMultiplier = 1.0,
			Aura = "EmberAura",
			Trail = "EmberTrail",
			Tint = Color3.fromRGB(255, 138, 61),
		},
		AnnounceServerWide = false,
	},

	Titan = {
		Id = "Titan",
		DisplayName = "Titan",
		Rarity = "Rare",
		Weight = 100,
		StatModifiers = { DamageMultiplier = 1.4, HealthMultiplier = 1.5, AttackSpeedMultiplier = 0.9 },
		Visual = {
			ScaleMultiplier = 1.9, -- the size gag is the whole point; it is the clip
			BodyMaterial = Enum.Material.Slate,
			Aura = "TitanDust",
		},
		AnnounceServerWide = true,
	},
}

local MutationConfig = {
	Mutations = Mutations,

	-- Rarity presentation. Colour is for UI text only, never for the Mini itself.
	RarityColors = {
		Common = Color3.fromRGB(180, 180, 180),
		Uncommon = Color3.fromRGB(105, 220, 120),
		Rare = Color3.fromRGB(80, 165, 255),
		Epic = Color3.fromRGB(190, 110, 255),
		Legendary = Color3.fromRGB(255, 190, 60),
		Mythic = Color3.fromRGB(255, 85, 120),
		Secret = Color3.fromRGB(30, 30, 30),
	},
}

-- Total weight across the roll table, used to derive displayed odds.
function MutationConfig.getTotalWeight(): number
	local total = 0
	for _, mutation in Mutations do
		total += mutation.Weight
	end
	return total
end

-- Odds of rolling a specific mutation, as a 0-1 fraction.
--
-- This exists because the odds MUST be shown to the player. Roblox tightened the
-- Paid Random Items policy in May 2026: any random outcome reachable with paid
-- currency needs numeric odds disclosed and regional gating via PolicyService.
-- We sidestep that entirely by making rolls cost earned currency only -- but we
-- still show the odds, because hiding them from kids is not something we do.
function MutationConfig.getOdds(id: string): number
	local mutation = Mutations[id]
	if not mutation then
		return 0
	end
	return mutation.Weight / MutationConfig.getTotalWeight()
end

return MutationConfig
