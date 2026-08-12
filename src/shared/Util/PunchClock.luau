--!strict
-- One clock, three consumers.
--
-- The Mini's fists are animated on the client, its training payout is calculated
-- on the server, and its fight damage is resolved on the server too. All three
-- derive punch N from the SAME epoch and rate, so nothing has to be sent per
-- punch and the three can never disagree about how many landed.
--
-- The epoch is a Workspace:GetServerTimeNow() timestamp, which both sides read
-- off the same synchronised clock.

local Workspace = game:GetService("Workspace")

local PunchClock = {}

-- How many punches have landed since the epoch. Zero while the Mini is still
-- walking in (a future epoch).
function PunchClock.landed(epoch: number, rate: number): number
	if rate <= 0 then
		return 0
	end

	local elapsed = Workspace:GetServerTimeNow() - epoch

	if elapsed < 0 then
		return 0
	end

	return math.floor(elapsed * rate)
end

-- (index, phase) for the punch currently being thrown, where phase is 0..1
-- through the swing. Returns nil while still walking in, so presentation can
-- hold a guard instead of starting mid-cycle.
function PunchClock.phase(epoch: number, rate: number): (number?, number?)
	if rate <= 0 then
		return nil, nil
	end

	local elapsed = Workspace:GetServerTimeNow() - epoch

	if elapsed < 0 then
		return nil, nil
	end

	local total = elapsed * rate
	local index = math.floor(total)

	return index, total - index
end

return PunchClock
