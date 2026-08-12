--!strict
-- The Mini is the product. Every number here changes how it reads on screen, so
-- treat changes as design decisions rather than tweaks.

return {
	-- Chibi proportions. We do NOT uniformly shrink the player's character --
	-- that produces an unreadable blob for avatars with large accessories or
	-- Rthro bodies. We build our own R6 rig and map appearance onto it.
Scale = {
-- Final Mini size relative to a normal Roblox avatar.
Overall = 0.35,

-- R15 keeps the real avatar rig so normal Roblox animations can be
-- mirrored directly. These are subtle collectible-figure adjustments,
-- not a replacement skeleton.
R15 = {
HeadMultiplier = 1.15,
HeightMultiplier = 0.90,
WidthMultiplier = 1.05,
DepthMultiplier = 1.05,
},
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

	-- What training LOOKS like. The cadence itself is published by the server
	-- (BaseStats.AttacksPerSecond); everything here is presentation the client
	-- runs locally, so twenty-four punching Minis cost no extra network traffic.
	Training = {
	-- How close to the training spot the Mini must be before it stops walking
	-- and starts working. Generous, because the last fraction of a stud is
	-- reached asymptotically by the arrival easing.
	ArriveRadiusStuds = 0.9,

	-- Following tolerates being roughly in place; punching does not. A Mini
	-- that parks a follow-sized 0.45 studs short of its spot swings at air,
	-- because the whole fighter is only two studs tall.
	SpotToleranceStuds = 0.06,

	-- One punch, as fractions of a full attack period: pull back, snap out,
	-- return to guard. The strike is deliberately much shorter than the
	-- recovery -- that contrast is what reads as "impact" rather than "wave".
	WindupFraction = 0.30,
	StrikeFraction = 0.16,

	-- Guard is the pose the Mini holds between punches; Punch is full
	-- extension. Degrees, applied to the shoulder and elbow of the working arm.
	GuardShoulderDegrees = 52,
	GuardElbowDegrees = 78,
	PunchShoulderDegrees = 88,
	PunchElbowDegrees = 8,
	-- The fist crosses toward the centre line as it lands, the way a real
	-- punch does. Without it a right hand lands on the edge of a bag that is
	-- only two thirds of a stud wide.
	PunchInwardDegrees = 34,

	-- The body follows the fist. Without this the Mini reads as a mannequin
	-- flapping an arm.
	TorsoTwistDegrees = 26,
	StanceLegDegrees = 9,
	KneeBendDegrees = 7,
	BobHeightStuds = 0.05,

	-- What a punch is WORTH. The bag is the feeder: every landed punch heals the
	-- Mini and makes it permanently stronger, so the player can watch the two
	-- numbers above its head climb and decide when it is ready to fight.
	PowerPerPunch = 1,
	-- The XP bar is the hook: a handful of punches fills it and the Mini gets a
	-- visible jump in both numbers. Levelling has to happen inside a player's
	-- attention span, not across a session.
	XpPerPunch = 10,
	XpForFirstLevel = 60,
	XpGrowthPerLevel = 1.22,
	-- What a level actually pays out, on top of the raised health ceiling.
	PowerPerLevel = 5,
	-- Coins trickle in while the Mini works. Small: the tower is where the real
	-- money is, and training should never be the better way to earn.
	CoinsPerPunch = 1,

	-- Health is the headline number, the way it is on a Chicken Fighter card:
	-- it visibly jumps on every single hit rather than creeping.
	HealthPerPunch = 25,

	-- Each level raises the ceiling the Mini has to fill back up, so a stronger
	-- Mini also takes longer to make battle-ready.
	HealthPerLevel = 120,
	-- Immediate heal on level up, on top of the raised ceiling. Makes the boost
	-- land as a jump in the bar rather than as a bar that suddenly got longer.
	HealthBoostPerLevel = 60,

	-- A brand new Mini wakes up weak. Without this the very first thing the
	-- player sees is a full bar with nothing to earn, and the entire point of
	-- the punching bag is invisible until combat exists to drain it.
	StartingHealthFraction = 0.12,

	-- The Mini walks to the dojo before it can throw anything. Server and client
	-- both offset the punch clock by this, so the count above its head and the
	-- fists on screen can never drift apart.
	WalkInSeconds = 1.5,

	-- Our own uploaded impact sample. Deliberately short-range -- the dojo is a
	-- toy-sized set the player leans over, not a stadium.
	PunchSoundId = "rbxassetid://107581892029163",
	PunchSoundVolume = 0.22,
	PunchSoundMinDistance = 6,
	PunchSoundMaxDistance = 70,
	-- Identical samples in a loop read as a machine gun; a little pitch spread
	-- reads as a person hitting something.
	PunchSoundPitchJitter = 0.12,

	-- Bag reaction, as a damped spring in radians about its top mount.
	BagImpulseRadiansPerSecond = 2.2,
	BagSwingStiffness = 46,
	BagSwingDamping = 4.2,
	MaxBagSwingRadians = 0.26,
	-- Below this the swing is invisible, so we stop touching the model.
	BagRestEpsilon = 0.0015,
	},

	-- The product promise: the fighter you are growing has to LOOK grown. A level
	-- that only moves a number is a level the player has to read to notice.
	Growth = {
	-- Per level, compounding on the Mini's base scale. Small enough that no
	-- single level looks like a glitch, big enough that ten of them are obvious
	-- standing next to somebody who has not levelled.
	ScalePerLevel = 0.025,
	-- The dojo is a fixed-size set at Mini scale, so the fighter cannot be
	-- allowed to outgrow its own gym. Raising this needs a bigger dojo to go
	-- with it -- which is a good upgrade to sell later.
	MaxScaleMultiplier = 1.30,

	-- Level-up presentation. PLACEHOLDER sound: free Creator Store asset, to be
	-- replaced when we do an audio pass.
	LevelUpSoundId = "rbxassetid://7381724959",
	LevelUpSoundVolume = 0.35,
	LevelUpSoundMaxDistance = 90,
	-- How long the burst of light and sparks lasts. Short: this fires every few
	-- punches early on, and anything longer becomes noise.
	LevelUpFlashSeconds = 0.45,
	},

	-- When the Mini is topped up it stops working and mooches around the dojo.
	-- That idling IS the user interface: no popup tells the player their fighter
	-- is ready, they just see it stop hitting things.
	Wander = {
	RadiusStuds = 1.6,

	-- Speed for every trip the Mini makes under its own steam: to the bag, out
	-- to the pit, home again. Deliberately far slower than MoveSpeed, which
	-- exists only to keep up with a running player. A two-stud-tall fighter
	-- covering eighteen studs a second does not run, it skates.
	TravelSpeedStuds = 6.5,
	-- Slow. A Mini that sprints between points reads as panicked rather than as
	-- a fighter with nothing to do.
	SpeedStuds = 2.4,
	PauseSecondsMin = 1.2,
	PauseSecondsMax = 3.0,

	-- Roblox's stock R15 walk cycle, played on the Mini's OWN Animator. While
	-- the Mini is on its own business the owner's pose is not mirrored, so it
	-- needs legs of its own -- see the ACTION STATE branch in MiniController.
	WalkAnimationId = "rbxassetid://507777826",
	WalkAnimationSpeed = 0.75,
	-- Hysteresis, so a Mini hovering around the threshold does not strobe
	-- between walking and idling.
	AnimateAboveStuds = 0.9,
	AnimateBelowStuds = 0.4,
	},

	-- The tower is where training gets spent. The Mini wins a few floors, dies,
	-- and walks home to the bag -- that round trip is the whole game loop.
	Tower = {
	-- Floor 1 must be winnable by a Mini that has only just filled up once.
	EnemyHealthBase = 40,
	EnemyHealthGrowth = 1.5,
	-- Damage per second the floor deals back. Grows slower than enemy health so
	-- fights get longer before they get lethal.
	EnemyDamageBase = 8,
	EnemyDamageGrowth = 1.34,
	CoinsBase = 8,
	CoinsGrowth = 1.35,

	-- Beat between floors, so a cleared floor reads as a win rather than the
	-- next enemy blinking into existence.
	FloorBreakSeconds = 1.1,
	-- How long the Mini lies there after losing. Long enough to register that it
	-- lost, short enough that nobody taps away.
	KnockoutSeconds = 1.6,

	-- Every run starts at the bottom. Fast early wins, escalating danger, and no
	-- run that begins with an instant death.
	StartFloor = 1,
	},

	-- Base stats before any upgrade or mutation. Kept deliberately small so the
	-- first upgrade is a visible jump rather than a rounding error.
	BaseStats = {
		Damage = 10,
		AttacksPerSecond = 1.0,
		CritChance = 0.05,
		CritMultiplier = 2.0,
		Health = 300,
	},
}
