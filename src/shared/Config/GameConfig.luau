--!strict
-- Global tunables. Anything a designer might want to change without reading
-- code belongs in a Config module, and this one holds the values that are not
-- specific to any single system.

local RunService = game:GetService("RunService")

return {
	-- Hard performance budget. Derived from the mobile-first target: 30 FPS on a
	-- 4 GB Android with a full 20-player server. Exceeding these is a bug, not a
	-- tuning question -- systems must queue or refuse rather than overshoot.
	MaxPlayersPerServer = 20,
	MaxActiveMinis = 24,
	MaxActiveEnemies = 40,

	-- Simulation rates in Hz. Only movement interpolation runs at full framerate;
	-- everything else ticks slowly enough that 40 enemies cost almost nothing.
	AiTickRate = 10,
	VfxTickRate = 30,

	-- Beyond this distance minis and enemies stop animating and drop particles.
	LodDistanceStuds = 80,

	-- Verbose service logging. On in Studio, off in production, so we never ship
	-- a chatty Output that hides real warnings.
	DebugLogging = RunService:IsStudio(),
}
