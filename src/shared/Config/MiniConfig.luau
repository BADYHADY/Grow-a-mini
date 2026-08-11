--!strict
-- The Mini is the product. Every number here changes how it reads on screen, so
-- treat changes as design decisions rather than tweaks.

return {
	-- Chibi proportions. We do NOT uniformly shrink the player's character --
	-- that produces an unreadable blob for avatars with large accessories or
	-- Rthro bodies. We build our own R6 rig and map appearance onto it.
	Scale = {
		Overall = 0.35,
		-- Multipliers applied on top of Overall, per body part, to get the
		-- collectible-figurine silhouette. Head oversized, limbs stubby.
		Head = 1.55,
		Torso = 1.0,
		Arm = 0.75,
		Leg = 0.7,
		-- Hands read as "chunky" by widening arms near the wrist only.
		HandWidthBoost = 1.35,
	},

	-- Appearance mapping rules. These exist to keep 24 minis cheap and readable.
	Appearance = {
		-- Layered clothing is mesh-deformation heavy and does not fit an R6 rig.
		-- We approximate with the classic shirt/pants textures instead.
		AllowLayeredClothing = false,
		-- Hats and hair carry most of the identity; anything past two becomes
		-- visual noise at 0.35 scale.
		MaxAccessories = 3,
		-- Reject accessories whose bounding box exceeds this on any axis (studs,
		-- measured at full avatar scale). Catches the joke-sized items that would
		-- otherwise be larger than the whole Mini.
		MaxAccessoryStuds = 4.0,

-- Head accessories carry identity far more strongly than back/shoulder
-- accessories. Hair, hats and face pieces get a larger allowance before
-- being classified as joke-sized.
MaxHeadAccessoryStuds = 8.0,
		-- Accessory types kept, in priority order, when trimming to MaxAccessories.
		AccessoryPriority = {
			Enum.AccessoryType.Hair,
			Enum.AccessoryType.Hat,
			Enum.AccessoryType.Face,
			Enum.AccessoryType.Back,
			Enum.AccessoryType.Shoulder,
		},
		-- How long a fetched HumanoidDescription stays cached on this server.
		CacheSeconds = 900,
		-- Appearance fetch must never block the spawn. We show a plain grey Mini
		-- immediately and swap in the real look when the fetch lands.
		FetchTimeoutSeconds = 8,
	},

	-- Movement and combat feel.
	FollowDistanceStuds = 6,
	MaxFollowDistanceStuds = 8,
	TeleportDistanceStuds = 60, -- snap back if it somehow falls this far behind
	MoveSpeed = 18,
AttackRangeStuds = 12,

-- Presentation-only companion feel. These values are consumed by the
-- client MiniController; the server never trusts them for combat state.
Personality = {
SideOffsetStuds = 3.0,
BackOffsetStuds = 2.6,

CatchUpStartStuds = 7.0,
MaxSpeedMultiplier = 2.4,

TurnResponsiveness = 13.0,

GroundProbeHeightStuds = 6,
GroundProbeDistanceStuds = 24,

MoveBobHeight = 0.035,
MoveBobFrequency = 8.5,

IdleBobHeight = 0.025,
IdleBobFrequency = 2.4,

WalkSwingDegrees = 20,
IdleArmDegrees = 5,
LeanDegrees = 5.0,

-- Natural locomotion. Mini accelerates into a run instead of snapping
-- to full speed, then brakes as it reaches its follow position.
StopRadiusStuds = 0.45,
ArrivalRadiusStuds = 2.8,
AccelerationStudsPerSecond2 = 52,
DecelerationStudsPerSecond2 = 70,
VerticalResponsiveness = 18,

-- Gait is driven by DISTANCE travelled, not wall-clock time.
-- This keeps the feet and body rhythm matched to actual movement speed.
GaitRadiansPerStud = 2.15,

-- Other players' Minis still move smoothly but do not need every
-- expensive personality detail at extreme distance.
FullPersonalityDistanceStuds = 80,
},

	-- Base stats before any upgrade or mutation. Kept deliberately small so the
	-- first upgrade is a visible jump rather than a rounding error.
	BaseStats = {
		Damage = 10,
		AttacksPerSecond = 1.0,
		CritChance = 0.05,
		CritMultiplier = 2.0,
		Health = 100,
	},
}
