--!nonstrict
-- The one place a player's instruction to their Mini turns into a state change.
--
-- The buttons on screen and the posts on the plot both land here. Routing every
-- command through a single arbiter is what stops "sent to the tower" and "told
-- to follow me" from ever being true at the same time.
--
-- Client sends an intent. This service decides what it means and whether it is
-- allowed; nothing about the Mini's state is ever set by the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Net.Remotes)

local MiniCommandService = {}

local AnalyticsService
local MiniService
local TowerService

local COMMANDS = {
	Follow = true,
	Train = true,
	Tower = true,
}

local function run(player: Player, command: unknown)
	if type(command) ~= "string" or not COMMANDS[command] then
		return
	end

	if command == "Tower" then
		-- Already out there: this is the button asking for it back.
		if TowerService.isFighting(player) then
			TowerService.recall(player)
			MiniService.enterTraining(player)
		else
			TowerService.send(player)
		end

		AnalyticsService.track(player, "MiniCommand", { command = "Tower" })
		return
	end

	-- Follow and Train both mean "stop whatever you are doing", so a Mini in the
	-- middle of a tower run comes home instead of ignoring the player.
	TowerService.recall(player)

	if command == "Follow" then
		MiniService.enterFollow(player)
	else
		MiniService.enterTraining(player)
	end

	AnalyticsService.track(player, "MiniCommand", { command = command })

	if GameConfig.DebugLogging then
		print(`[MiniCommandService] {player.Name}: {command}`)
	end
end

function MiniCommandService.Init(registry)
	AnalyticsService = registry.AnalyticsService
	MiniService = registry.MiniService
	TowerService = registry.TowerService
end

function MiniCommandService.Start()
	-- Generous enough for a player tapping a button, tight enough that a script
	-- cannot thrash the Mini's state machine.
	Remotes.bind("MiniCommand", { perSecond = 3, burst = 6 }, run)
end

return MiniCommandService
