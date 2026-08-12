--!nonstrict
-- Walking a Humanoid from A to B, the way Roblox documents it.
--
-- This replaces a hand-rolled "call MoveTo at the destination every quarter
-- second and hope" loop, which is not how PathfindingService is meant to be
-- driven and which fails in exactly the ways the docs warn about: it walks into
-- walls, it never notices it is stuck, and it cannot recover when something
-- moves into the way.
--
-- The documented shape, from create.roblox.com/docs/characters/pathfinding:
--
--   1. CreatePath with agent parameters that describe THIS character, not a
--      player. Ours is a two-stud fighter; sized as an adult, every doorway on
--      the map reads as impassable and ComputeAsync returns NoPath.
--   2. ComputeAsync, then GetWaypoints.
--   3. Walk the waypoints in order, waiting on MoveToFinished for each.
--   4. Listen to Path.Blocked. If the blockage is AHEAD of where we are, throw
--      the path away and compute a new one; if it is behind, ignore it.
--   5. Humanoid:MoveTo gives up on its own after eight seconds, so anything
--      further than that has to be re-issued or it silently stops.
--
-- One agent per Humanoid. Calling walkTo again cancels whatever walk was in
-- progress, which is what makes a player's command take effect immediately
-- rather than after the Mini finishes what it was already doing.

local PathfindingService = game:GetService("PathfindingService")

local PathAgent = {}
PathAgent.__index = PathAgent

-- Humanoid:MoveTo abandons a walk after eight seconds without arriving. Legs
-- longer than that are re-issued before it can.
local MOVE_REISSUE_SECONDS = 6

-- A leg that has not finished by now is a Mini wedged on scenery. Give up on
-- the path rather than stand there for the rest of the session.
local LEG_TIMEOUT_SECONDS = 12

-- How many times a blocked path may be recomputed before we accept that the
-- destination cannot be reached this way and walk at it directly.
local MAX_RECOMPUTES = 3

export type Agent = typeof(setmetatable({}, PathAgent))

function PathAgent.new(
	humanoid: Humanoid,
	agentParameters: { [string]: any }?,
	arriveRadius: number?
): Agent
	return setmetatable({
		humanoid = humanoid,
		parameters = agentParameters or {},
		-- Waypoints are corners to round, not marks to hit. Too tight and the
		-- character grinds to a halt at every one of them; too loose and it
		-- cuts the corner into whatever the corner was avoiding.
		arriveRadius = arriveRadius or 1.0,
		-- Bumped on every new order. A walk in progress compares against this
		-- and abandons itself the moment it no longer matches.
		generation = 0,
		walking = false,
	}, PathAgent)
end

function PathAgent.isWalking(self: Agent): boolean
	return self.walking
end

-- Abandon whatever is in progress. Safe to call when nothing is.
function PathAgent.cancel(self: Agent)
	self.generation += 1
	self.walking = false
end

local function rootOf(humanoid: Humanoid): BasePart?
	return humanoid.RootPart
end

-- Walk one waypoint. Returns "arrived", "superseded" or "stuck".
local function walkTo(self: Agent, point: Vector3, generation: number): string
	local humanoid = self.humanoid
	local deadline = os.clock() + LEG_TIMEOUT_SECONDS
	local reissueAt = 0

	while os.clock() < deadline do
		if self.generation ~= generation or not humanoid.Parent then
			return "superseded"
		end

		local root = rootOf(humanoid)

		if not root then
			return "stuck"
		end

		-- Flat distance: the waypoint is on the floor and the root is at hip
		-- height, so a height difference is not a reason to keep walking.
		local flat = Vector3.new(
			point.X - root.Position.X,
			0,
			point.Z - root.Position.Z
		)

		if flat.Magnitude <= self.arriveRadius then
			return "arrived"
		end

		if os.clock() >= reissueAt then
			humanoid:MoveTo(point)
			reissueAt = os.clock() + MOVE_REISSUE_SECONDS
		end

		task.wait(0.1)
	end

	return "stuck"
end

-- Compute a route and walk it. Yields until the Mini arrives, gets stuck, or is
-- given a different order. Returns true only if it actually got there.
--
-- `onWaypoints` is handed the computed route, so the caller can publish it or
-- measure its length without recomputing.
function PathAgent.walkTo(
	self: Agent,
	destination: Vector3,
	onWaypoints: ((points: { Vector3 }) -> ())?
): boolean
	self.generation += 1

	local generation = self.generation
	local humanoid = self.humanoid

	self.walking = true

	local function finish(result: boolean): boolean
		-- Only the newest walk is allowed to say it has stopped walking.
		if self.generation == generation then
			self.walking = false
		end

		return result
	end

	for attempt = 1, MAX_RECOMPUTES + 1 do
		if self.generation ~= generation then
			return finish(false)
		end

		local root = rootOf(humanoid)

		if not root then
			return finish(false)
		end

		local path = PathfindingService:CreatePath(self.parameters)
		local blockedAt: number? = nil

		-- Only blockages AHEAD of us matter; something closing the door behind
		-- the Mini is not a reason to replan.
		local blockedConnection = path.Blocked:Connect(function(waypointIndex: number)
			blockedAt = waypointIndex
		end)

		local ok = pcall(path.ComputeAsync, path, root.Position, destination)
		local points: { Vector3 } = {}

		if ok and path.Status == Enum.PathStatus.Success then
			for index, waypoint in path:GetWaypoints() do
				-- The first waypoint is where the character already stands.
				if index > 1 then
					table.insert(points, waypoint.Position)
				end
			end
		end

		if #points == 0 then
			-- No route exists. Walking straight at it beats refusing to move:
			-- the destination may be inside scenery that is not in the navmesh,
			-- which is exactly the case for our two doorless models.
			blockedConnection:Disconnect()

			if onWaypoints then
				onWaypoints({ destination })
			end

			local result = walkTo(self, destination, generation)
			return finish(result == "arrived")
		end

		if onWaypoints then
			onWaypoints(points)
		end

		local recompute = false

		for index, point in points do
			local result = walkTo(self, point, generation)

			if result == "superseded" then
				blockedConnection:Disconnect()
				return finish(false)
			end

			if result == "stuck" then
				recompute = true
				break
			end

			-- Something dropped into the path in front of us.
			if blockedAt and blockedAt >= index then
				recompute = true
				break
			end
		end

		blockedConnection:Disconnect()

		if not recompute then
			return finish(true)
		end
	end

	return finish(false)
end

return PathAgent
