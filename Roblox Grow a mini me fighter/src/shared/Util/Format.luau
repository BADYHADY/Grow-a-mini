--!strict
-- Number and time formatting for UI.
--
-- Players read "12.4K" instantly and "12,431" not at all. Abbreviate everywhere
-- except exact prices, where seeing the real number matters for trust.

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

function Format.abbreviate(value: number): string
	if value < 1000 then
		return tostring(math.floor(value))
	end

	local tier = math.floor(math.log(math.abs(value), 1000))
	tier = math.clamp(tier, 1, #SUFFIXES - 1)

	local scaled = value / 1000 ^ tier
	-- One decimal below 100, none above, so the string never gets wide enough to
	-- reflow a button label.
	if scaled < 100 then
		return string.format("%.1f%s", scaled, SUFFIXES[tier + 1])
	end
	return string.format("%d%s", math.floor(scaled), SUFFIXES[tier + 1])
end

-- Exact number with thousands separators. For prices and confirmations.
function Format.exact(value: number): string
	local text = tostring(math.floor(value))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

function Format.percent(fraction: number, decimals: number?): string
	return string.format("%." .. (decimals or 0) .. "f%%", fraction * 100)
end

-- "8h 13m" style. Used by the offline training report, where the exact duration
-- is part of the reward feeling.
function Format.duration(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	local hours = math.floor(total / 3600)
	local minutes = math.floor((total % 3600) / 60)

	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm", minutes)
	end
	return string.format("%ds", total)
end

-- "1 in 25,000" -- how rarity is communicated to players. Reads far better than
-- "0.004%" for the age group we are building for.
function Format.odds(fraction: number): string
	if fraction <= 0 then
		return "impossible"
	end
	return "1 in " .. Format.exact(math.round(1 / fraction))
end

return Format
