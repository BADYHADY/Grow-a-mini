--!nonstrict
-- Server entry point.
--
-- Services are loaded in an explicit order rather than by folder iteration, so
-- dependencies are visible in one place and a new service cannot accidentally
-- change startup order by being named "AAA".
--
-- Rule: a service may only depend on services listed ABOVE it in LOAD_ORDER.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)

local LOAD_ORDER = {
	"AnalyticsService",
	"DataService",
	"MiniAvatarService",
	"MiniBaseService",
	"MiniService",
	"TrainingService",
	"TowerService",
	"MiniCommandService",
}

local registry = {}

local function log(message: string)
	if GameConfig.DebugLogging then
		print(`[Server] {message}`)
	end
end

local startClock = os.clock()

-- Require everything first so Init can safely reference any other service.
for _, name in LOAD_ORDER do
	local module = script.Services:FindFirstChild(name)
	assert(module, `LOAD_ORDER lists "{name}" but src/server/Services/{name}.luau does not exist`)

	local service = require(module)
	service.Name = name
	registry[name] = service
end

for _, name in LOAD_ORDER do
	local service = registry[name]
	if service.Init then
		local ok, err = pcall(service.Init, registry)
		-- A service that fails to initialise leaves the game in an undefined
		-- state. Fail loudly here rather than debugging a mystery three systems
		-- later.
		assert(ok, `{name}.Init failed: {err}`)
		log(`{name} initialised`)
	end
end

for _, name in LOAD_ORDER do
	local service = registry[name]
	if service.Start then
		-- Start may yield (loops, waits), so each runs in its own thread.
		task.spawn(function()
			local ok, err = pcall(service.Start, registry)
			if not ok then
				warn(`[Server] {name}.Start failed: {err}`)
			end
		end)
		log(`{name} started`)
	end
end

log(string.format("boot complete in %.0f ms (%d services)", (os.clock() - startClock) * 1000, #LOAD_ORDER))
