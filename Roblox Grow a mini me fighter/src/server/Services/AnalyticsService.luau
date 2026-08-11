--!nonstrict
-- Funnel instrumentation.
--
-- This exists in the first commit on purpose. The onboarding funnel is the only
-- thing that tells us whether minute one works, and Roblox's own discovery
-- algorithm weights first-play bounce heavily -- a game that cannot see where
-- players drop out cannot fix it.
--
-- Right now events go to Output and to Roblox's AnalyticsService. When we have
-- volume, add an external sink here; nothing else has to change.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RobloxAnalytics = game:GetService("AnalyticsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local GameConfig = require(Shared.Config.GameConfig)

-- The onboarding funnel, in order. Every step a new player passes through
-- between joining and their first real goal. Keep this list ordered -- the
-- funnel report reads it top to bottom.
local ONBOARDING_FUNNEL = {
	"SessionStart",
	"CharacterLoaded",
	"MiniGenerated",
	"MiniAppearanceApplied",
	"FirstAttack",
	"FirstKill",
	"FirstUpgrade",
	"AbilityUnlocked",
	"FirstBossKill",
	"FirstMutation",
	"PitEntered",
	"Min5",
	"Min10",
}

local FUNNEL_NAME = "Onboarding"

local AnalyticsService = {}

-- [Player] = { [eventName]: true } -- guards TrackOnce
local fired: { [Player]: { [string]: boolean } } = {}
local joinClock: { [Player]: number } = {}

local function funnelStep(eventName: string): number?
	local index = table.find(ONBOARDING_FUNNEL, eventName)
	return index
end

-- Record an event. `props` is optional context; keep it to gameplay facts and
-- never put anything personally identifying in it.
function AnalyticsService.track(player: Player, eventName: string, props: { [string]: any }?)
	if GameConfig.DebugLogging then
		local elapsed = joinClock[player] and string.format("%.1fs", os.clock() - joinClock[player]) or "?"
		print(`[Analytics] {player.Name} @{elapsed} :: {eventName}`, props or "")
	end

	local step = funnelStep(eventName)
	if step then
		-- LogOnboardingFunnelStepEvent is the Roblox-side funnel; it powers the
		-- retention dashboards we benchmark against.
		local ok, err = pcall(function()
			RobloxAnalytics:LogOnboardingFunnelStepEvent(player, step, eventName)
		end)
		if not ok and GameConfig.DebugLogging then
			warn(`[Analytics] funnel log failed: {err}`)
		end
	end
end

-- Fire at most once per player per session. Use for every "first X" event --
-- firing FirstKill on every kill makes the funnel meaningless.
function AnalyticsService.trackOnce(player: Player, eventName: string, props: { [string]: any }?)
	local seen = fired[player]
	if not seen then
		seen = {}
		fired[player] = seen
	end

	if seen[eventName] then
		return
	end
	seen[eventName] = true

	AnalyticsService.track(player, eventName, props)
end

function AnalyticsService.Init()
	-- Rejected remotes are a security signal and a bug signal at the same time:
	-- a spike usually means either an exploiter or a client loop we wrote badly.
	Remotes.Rejected:Connect(function(player: Player, remoteName: string, reason: string)
		AnalyticsService.track(player, "RemoteRejected", { remote = remoteName, reason = reason })
	end)
end

function AnalyticsService.Start()
	Players.PlayerAdded:Connect(function(player)
		joinClock[player] = os.clock()
		AnalyticsService.track(player, "SessionStart")

		-- The 5 and 10 minute marks are the two thresholds that matter most for
		-- the algorithm's playtime signal, so they are tracked as funnel steps
		-- rather than derived later from session length.
		task.delay(300, function()
			if player.Parent == Players then
				AnalyticsService.trackOnce(player, "Min5")
			end
		end)
		task.delay(600, function()
			if player.Parent == Players then
				AnalyticsService.trackOnce(player, "Min10")
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local seconds = joinClock[player] and os.clock() - joinClock[player] or 0
		AnalyticsService.track(player, "SessionEnd", { seconds = math.floor(seconds) })

		fired[player] = nil
		joinClock[player] = nil
	end)
end

AnalyticsService.ONBOARDING_FUNNEL = ONBOARDING_FUNNEL
AnalyticsService.FUNNEL_NAME = FUNNEL_NAME

return AnalyticsService
