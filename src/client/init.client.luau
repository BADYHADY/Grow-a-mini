--!nonstrict
-- Client entry point. Same two-phase loader as the server.
--
-- Controllers own presentation only: input, UI, camera, VFX, audio. If a
-- controller decides something that affects game state, it is in the wrong file.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)

local LOAD_ORDER = {
	"DebugController",
	"MiniController",
}

local registry = {}

local function log(message: string)
	if GameConfig.DebugLogging then
		print(`[Client] {message}`)
	end
end

for _, name in LOAD_ORDER do
	local module = script.Controllers:FindFirstChild(name)
	assert(module, `LOAD_ORDER lists "{name}" but src/client/Controllers/{name}.luau does not exist`)

	local controller = require(module)
	controller.Name = name
	registry[name] = controller
end

for _, name in LOAD_ORDER do
	local controller = registry[name]
	if controller.Init then
		local ok, err = pcall(controller.Init, registry)
		assert(ok, `{name}.Init failed: {err}`)
		log(`{name} initialised`)
	end
end

for _, name in LOAD_ORDER do
	local controller = registry[name]
	if controller.Start then
		task.spawn(function()
			local ok, err = pcall(controller.Start, registry)
			if not ok then
				warn(`[Client] {name}.Start failed: {err}`)
			end
		end)
		log(`{name} started`)
	end
end

log(`boot complete ({#LOAD_ORDER} controllers)`)
