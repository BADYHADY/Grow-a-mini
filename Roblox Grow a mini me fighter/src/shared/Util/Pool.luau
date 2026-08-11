--!nonstrict
-- Object pool for anything that spawns and despawns constantly: enemies, damage
-- numbers, coins, hit sparks.
--
-- Instance.new and Destroy in the combat hot path is the single biggest source
-- of frame spikes on low-end Android. Pooling turns that cost into a one-time
-- warmup. Rule: nothing in the combat loop calls Instance.new directly.

local Pool = {}
Pool.__index = Pool

-- Parked far below the map rather than in ReplicatedStorage, so pooled parts
-- keep their rendering state and do not re-stream when reused.
local PARK_CFRAME = CFrame.new(0, -500, 0)

export type Pool = typeof(setmetatable(
	{} :: {
		_template: Instance,
		_parent: Instance,
		_idle: { Instance },
		_activeCount: number,
		_maxActive: number,
	},
	Pool
))

function Pool.new(template: Instance, parent: Instance, config: { initialSize: number?, maxActive: number? }?): Pool
	local settings = config or {}
	local self = setmetatable({
		_template = template,
		_parent = parent,
		_idle = {},
		_activeCount = 0,
		_maxActive = settings.maxActive or math.huge,
	}, Pool)

	for _ = 1, settings.initialSize or 0 do
		local instance = template:Clone()
		Pool._park(instance)
		instance.Parent = parent
		table.insert(self._idle, instance)
	end

	return self
end

function Pool._park(instance: Instance)
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			instance:PivotTo(PARK_CFRAME)
		end
	elseif instance:IsA("BasePart") then
		instance.CFrame = PARK_CFRAME
	end
end

-- Returns nil when the active budget is exhausted. Callers must handle that
-- rather than forcing a spawn -- the budget exists to protect the frame time.
function Pool:get(): Instance?
	if self._activeCount >= self._maxActive then
		return nil
	end

	local instance = table.remove(self._idle)
	if not instance then
		instance = self._template:Clone()
		instance.Parent = self._parent
	end

	self._activeCount += 1
	return instance
end

function Pool:release(instance: Instance)
	Pool._park(instance)
	self._activeCount -= 1
	table.insert(self._idle, instance)
end

function Pool:getActiveCount(): number
	return self._activeCount
end

function Pool:destroy()
	for _, instance in self._idle do
		instance:Destroy()
	end
	table.clear(self._idle)
	self._activeCount = 0
end

return Pool
