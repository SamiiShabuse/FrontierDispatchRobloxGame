local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local screenGui = script.Parent
local mainLabel = screenGui:WaitForChild("Main")
local toastLabel = screenGui:WaitForChild("Toast")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateUI = Remotes:WaitForChild("UpdateUI")
local Notify = Remotes:WaitForChild("Notify")
local PickContracts = Remotes:WaitForChild("PickContracts")
local SelectRoute = Remotes:WaitForChild("SelectRoute")
local BuyUpgrade = Remotes:WaitForChild("BuyUpgrade")
local RequestContracts = Remotes:WaitForChild("RequestContracts")

local function getFallbackConfig()
	return {
		LoopPhases = { "MorningDispatch", "RouteStrategy", "TravelDynamicEvents", "DeliveryOutcome", "SystemEvolution" },
		Contracts = {
			CarryLimitMin = 2,
			CarryLimitMax = 3,
		},
		MVP = {
			Towns = 3,
			RandomEventTypes = 3,
		},
		Upgrades = {},
	}
end

local function resolveGameConfigModule()
	local shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 3)
	if shared then
		local fromShared = shared:FindFirstChild("GameConfig") or shared:WaitForChild("GameConfig", 3)
		if fromShared and fromShared:IsA("ModuleScript") then
			return fromShared
		end
	end

	local fromRoot = ReplicatedStorage:FindFirstChild("GameConfig") or ReplicatedStorage:WaitForChild("GameConfig", 2)
	if fromRoot and fromRoot:IsA("ModuleScript") then
		return fromRoot
	end

	return nil
end

local GameConfig = getFallbackConfig()
local gameConfigModule = resolveGameConfigModule()
if gameConfigModule then
	local ok, loadedConfig = pcall(require, gameConfigModule)
	if ok and type(loadedConfig) == "table" then
		GameConfig = loadedConfig
	else
		warn("[HUDClient] Failed to require GameConfig module, using fallback config.")
	end
else
	warn("[HUDClient] GameConfig not found in ReplicatedStorage.Shared or ReplicatedStorage root, using fallback config.")
end

local lastPayload = nil
local notifyQueue = {}
local showingToast = false
local completionCard = nil
local completionAnimationId = 0
local completionActive = false
local hasSeenCashBaseline = false
local lastKnownCash = 0

local RESOURCE_ORDER = { "Food", "Medicine", "Tools", "Gold", "Water", "Payroll" }
local PHASE_LABELS = {
	MorningDispatch = "Morning Dispatch",
	RouteStrategy = "Route Strategy",
	TravelDynamicEvents = "Travel + Events",
	DeliveryOutcome = "Delivery Outcome",
	SystemEvolution = "System Evolution",
}
local THEME = {
	MainBg = Color3.fromRGB(20, 27, 39),
	MainBorder = Color3.fromRGB(62, 90, 130),
	MainText = Color3.fromRGB(228, 235, 245),
	Accent = Color3.fromRGB(116, 205, 255),
	Dim = Color3.fromRGB(160, 176, 198),
	ToastBg = Color3.fromRGB(29, 46, 66),
	ToastText = Color3.fromRGB(240, 246, 255),
	CompleteBg = Color3.fromRGB(25, 51, 40),
	CompleteBorder = Color3.fromRGB(72, 209, 146),
	CompleteText = Color3.fromRGB(231, 255, 245),
}

local function ensureCorner(guiObject, radius)
	if guiObject:FindFirstChild("HUDCorner") then
		return
	end
	local corner = Instance.new("UICorner")
	corner.Name = "HUDCorner"
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = guiObject
end

local function ensureStroke(guiObject, color, thickness)
	local stroke = guiObject:FindFirstChild("HUDStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Name = "HUDStroke"
		stroke.Parent = guiObject
	end
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = 0.15
end

local function styleTextObject(textObject, isToast)
	textObject.RichText = true
	textObject.TextXAlignment = Enum.TextXAlignment.Left
	textObject.TextYAlignment = Enum.TextYAlignment.Top
	textObject.TextWrapped = true
	textObject.Font = Enum.Font.Gotham
	textObject.TextSize = isToast and 15 or 14
	textObject.TextColor3 = isToast and THEME.ToastText or THEME.MainText
	textObject.BackgroundTransparency = 0.12
	textObject.BackgroundColor3 = isToast and THEME.ToastBg or THEME.MainBg
	textObject.BorderSizePixel = 0
	ensureCorner(textObject, isToast and 10 or 12)
	ensureStroke(textObject, isToast and THEME.Accent or THEME.MainBorder, isToast and 1.25 or 1.5)
end

local function applyHUDStyling()
	if mainLabel:IsA("TextLabel") or mainLabel:IsA("TextButton") or mainLabel:IsA("TextBox") then
		styleTextObject(mainLabel, false)
	end
	if toastLabel:IsA("TextLabel") or toastLabel:IsA("TextButton") or toastLabel:IsA("TextBox") then
		styleTextObject(toastLabel, true)
		toastLabel.Visible = false
	end
end

local function ensureCompletionCard()
	if completionCard and completionCard.Parent then
		return completionCard
	end

	completionCard = Instance.new("TextLabel")
	completionCard.Name = "CompletionCard"
	completionCard.AnchorPoint = Vector2.new(0.5, 0.5)
	completionCard.Position = UDim2.fromScale(0.5, 0.3)
	completionCard.Size = UDim2.fromScale(0.5, 0.2)
	completionCard.BackgroundColor3 = THEME.CompleteBg
	completionCard.BackgroundTransparency = 0.08
	completionCard.TextColor3 = THEME.CompleteText
	completionCard.TextWrapped = true
	completionCard.TextXAlignment = Enum.TextXAlignment.Center
	completionCard.TextYAlignment = Enum.TextYAlignment.Center
	completionCard.Font = Enum.Font.GothamBold
	completionCard.TextSize = 22
	completionCard.RichText = true
	completionCard.BorderSizePixel = 0
	completionCard.Visible = false
	completionCard.ZIndex = 20
	completionCard.Parent = screenGui
	ensureCorner(completionCard, 14)
	ensureStroke(completionCard, THEME.CompleteBorder, 2)

	return completionCard
end

local function shouldHideMainHUD(payload)
	if completionActive then
		return true
	end

	local phase = tostring(payload.phase or payload.currentPhase or "")
	local activeContracts = payload.activeContracts or {}
	if (phase == "RouteStrategy" or phase == "TravelDynamicEvents") and #activeContracts > 0 then
		return true
	end

	return false
end

local function setMainHUDVisibility(payload)
	mainLabel.Visible = not shouldHideMainHUD(payload)
end

local function animateCompletionPayout(previousCash, newCash)
	local card = ensureCompletionCard()
	completionAnimationId += 1
	local animationId = completionAnimationId
	local gain = math.max(0, newCash - previousCash)

	completionActive = true
	mainLabel.Visible = false
	card.Visible = true

	card.Text = string.format(
		"<b>CONTRACT COMPLETE</b>\nCongratulations! Great delivery.\n$%d -> $%d",
		previousCash,
		previousCash
	)

	local duration = 1.2
	local steps = 24
	for i = 1, steps do
		if animationId ~= completionAnimationId then
			return
		end
		local alpha = i / steps
		local current = previousCash + math.floor(gain * alpha)
		card.Text = string.format(
			"<b>CONTRACT COMPLETE</b>\nCongratulations! Great delivery.\nCash: $%d <font color=\"#80FFB8\">(+%d)</font>",
			current,
			current - previousCash
		)
		task.wait(duration / steps)
	end

	if animationId ~= completionAnimationId then
		return
	end

	task.wait(1.4)
	if animationId ~= completionAnimationId then
		return
	end

	card.Visible = false
	completionActive = false
	if lastPayload then
		setMainHUDVisibility(lastPayload)
	end
end

local function getCarryLimits(payload)
	local cfg = GameConfig.Contracts or {}
	local p = payload.player or {}
	local maxCarry = tonumber(p.carryLimit) or cfg.CarryLimitMax or 2
	local minCarry = tonumber(p.minCarryLimit) or cfg.CarryLimitMin or 2
	return minCarry, maxCarry
end

local function hasUpgrade(payload, tierName, upgradeName)
	local upgrades = (payload.player and payload.player.upgrades) or {}
	if upgrades[upgradeName] == true then
		return true
	end
	if tierName and upgrades[tierName .. "." .. upgradeName] == true then
		return true
	end
	return false
end

local function formatTownDemand(demand)
	local parts = {}
	for _, resourceName in ipairs(RESOURCE_ORDER) do
		if demand[resourceName] ~= nil then
			table.insert(parts, resourceName .. ":" .. tostring(demand[resourceName]))
		end
	end

	if #parts == 0 then
		return "(no demand)"
	end
	return table.concat(parts, " ")
end

local function formatDuration(totalSeconds)
	local seconds = math.max(0, tonumber(totalSeconds) or 0)
	local minutes = math.floor(seconds / 60)
	local remain = seconds % 60
	return string.format("%02d:%02d", minutes, remain)
end

local function formatTowns(payload)
	local towns = payload.towns or {}
	local showDemand = hasUpgrade(payload, "Tier1Visibility", "DemandBoard")
	local showSatisfaction = hasUpgrade(payload, "Tier1Visibility", "SatisfactionMeter")
	local names = {}
	for townName, _ in pairs(towns) do
		table.insert(names, townName)
	end
	table.sort(names)

	if #names == 0 then
		return "<font color=\"#74CDFF\"><b>TOWNS</b></font>\n<font color=\"#A0B0C6\">No town data yet.</font>"
	end

	local lines = {}
	for _, townName in ipairs(names) do
		local t = towns[townName] or {}
		local d = t.Demand or {}
		local stability = tonumber(t.Stability or t.stability or 0) or 0
		local trust = tonumber(t.Trust or t.trust or 0) or 0
		local population = t.Population or t.population or "?"
		local info = {}

		if showSatisfaction then
			local stabilityBar = string.rep("|", math.max(1, math.floor(stability / 10)))
			local trustBar = string.rep("|", math.max(1, math.floor(trust / 10)))
			table.insert(info, string.format("S:%d %s", stability, stabilityBar))
			table.insert(info, string.format("T:%d %s", trust, trustBar))
		else
			table.insert(info, "S/T: unlock SatisfactionMeter")
		end

		table.insert(info, "P:" .. tostring(population))

		table.insert(
			lines,
			string.format(
				"%s | %s | %s",
				townName,
				table.concat(info, " "),
				showDemand and formatTownDemand(d) or "Demand: unlock DemandBoard"
			)
		)
	end

	return "<font color=\"#74CDFF\"><b>TOWNS</b></font>\n" .. table.concat(lines, "\n")
end

local function formatContracts(list, minCarry, maxCarry)
	if not list or #list == 0 then
		return "<font color=\"#A0B0C6\">No available contracts.</font>"
	end

	local lines = {}
	for i, c in ipairs(list) do
		local deadline = c.Deadline or c.deadlineHours or "?"
		local eta = c.DueAt and (" ETA:" .. formatDuration((tonumber(c.DueAt) or 0) - os.time())) or ""
		table.insert(
			lines,
			string.format(
				"%d) %s -> %s | $%d | U%s | DL:%sh%s",
				i,
				tostring(c.Resource or c.resource or "?"),
				tostring(c.Town or c.town or "?"),
				tonumber(c.Payout or c.payout) or 0,
				tostring(c.Urgency or c.urgency or 1),
				tostring(deadline),
				eta
			)
		)
	end

	table.insert(lines, "")
	table.insert(lines, string.format("Command: /pick i j (up to %d picks)", maxCarry))
	table.insert(lines, string.format("Carry limit: %d to %d", minCarry, maxCarry))
	return table.concat(lines, "\n")
end

local function formatActiveContracts(list)
	if not list or #list == 0 then
		return "<font color=\"#A0B0C6\">No active deliveries.</font>"
	end

	local lines = {}
	for i, c in ipairs(list) do
		local status = c.Status or c.status or "Active"
		local eta = c.DueAt and (" | ETA:" .. formatDuration((tonumber(c.DueAt) or 0) - os.time())) or ""
		table.insert(
			lines,
			string.format(
				"%d) %s -> %s | %s%s",
				i,
				tostring(c.Resource or c.resource or "?"),
				tostring(c.Town or c.town or "?"),
				tostring(status),
				eta
			)
		)
	end
	return table.concat(lines, "\n")
end

local function formatEvents(payload)
	local events = payload.activeEvents or payload.events or {}
	local lines = {}

	if payload.lastEvent then
		table.insert(lines, "Last: " .. tostring(payload.lastEvent))
	end

	if type(events) == "table" and #events > 0 then
		table.insert(lines, "Active: " .. table.concat(events, ", "))
	end

	if #lines == 0 then
		return "<font color=\"#74CDFF\"><b>LIVE EVENTS</b></font>\n<font color=\"#A0B0C6\">No active disruptions.</font>"
	end
	return "<font color=\"#74CDFF\"><b>LIVE EVENTS</b></font>\n" .. table.concat(lines, "\n")
end

local function formatUpgrades(payload)
	local p = payload.player or {}
	local upgrades = p.upgrades or {}
	local lines = {}

	for tierName, tierData in pairs(GameConfig.Upgrades or {}) do
		for upgradeName, _ in pairs(tierData) do
			local hasUpgrade = upgrades[upgradeName] == true or upgrades[tierName .. "." .. upgradeName] == true
			table.insert(lines, string.format("%s/%s: %s", tierName, upgradeName, hasUpgrade and "OWNED" or "LOCKED"))
		end
	end

	table.sort(lines)
	if #lines == 0 then
		return "<font color=\"#74CDFF\"><b>UPGRADES</b></font>\n<font color=\"#A0B0C6\">No upgrades tracked yet.</font>"
	end

	local ownedCount = 0
	for _, line in ipairs(lines) do
		if string.find(line, "OWNED", 1, true) then
			ownedCount += 1
		end
	end

	return "<font color=\"#74CDFF\"><b>UPGRADES</b></font>\nOwned: " .. tostring(ownedCount) .. "\n" .. table.concat(lines, "\n")
end

local function formatPhase(payload)
	local phase = payload.phase or payload.currentPhase or "MorningDispatch"
	local day = payload.day or payload.dayNumber or 1
	local objective = payload.objective or "Pick contracts at the depot."
	local displayPhase = PHASE_LABELS[tostring(phase)] or tostring(phase)
	local routeHint = "Phase flow: " .. table.concat(GameConfig.LoopPhases or {}, " -> ")
	local routeSelectHint = ""
	if payload.phase == "RouteStrategy" and type(payload.routeOptions) == "table" and #payload.routeOptions > 0 then
		local first = payload.routeOptions[1]
		if first and first.Id and payload.routeTown then
			routeSelectHint = string.format("\n<font color=\"#A0B0C6\">Pick route: /route %s %s</font>", tostring(payload.routeTown), tostring(first.Id))
		end
	end

	return string.format(
		"<font color=\"#74CDFF\"><b>FRONTIER DISPATCH</b></font>\nDay %s  |  %s\n<font color=\"#A0B0C6\">%s</font>\n<font color=\"#A0B0C6\">%s</font>%s",
		tostring(day),
		tostring(displayPhase),
		tostring(objective),
		routeHint,
		routeSelectHint
	)
end

local function formatMVPStatus(payload)
	local townCount = 0
	for _, _ in pairs(payload.towns or {}) do
		townCount += 1
	end
	local contractCount = #(payload.contracts or {})

	return string.format(
		"<font color=\"#74CDFF\"><b>MVP TRACKER</b></font>\nTowns: %d/%d | Contracts: %d | Event types target: %d",
		townCount,
		(GameConfig.MVP and GameConfig.MVP.Towns) or 3,
		contractCount,
		(GameConfig.MVP and GameConfig.MVP.RandomEventTypes) or 3
	)
end

local function formatPlayerSection(payload)
	local p = payload.player or {}
	local minCarry, maxCarry = getCarryLimits(payload)
	local available = formatContracts(payload.contracts, minCarry, maxCarry)
	local active = formatActiveContracts(payload.activeContracts)

	local priorityLine = "Priority: (none)"
	if p.priority and (hasUpgrade(payload, "Tier2Automation", "PriorityDispatch") or p.hasTelegraph) then
		priorityLine = "Priority: " .. tostring(p.priority.resource) .. " -> " .. tostring(p.priority.town)
	end
	local routeLine = "Route: (not selected)"
	if p.route then
		routeLine = "Route: " .. tostring(p.route.displayName or p.route.routeId or "selected")
	end
	local depotLine = (p.readyForDepot and "Depot: return now for next day") or "Depot: active run"

	return "<font color=\"#74CDFF\"><b>DISPATCHER</b></font>\n"
		.. "Score: " .. tostring(p.score or 0) .. "\n"
		.. "Cash: $" .. tostring(p.cash or p.money or 0) .. "\n"
		.. "Telegraph: " .. ((p.hasTelegraph and "ONLINE") or "OFFLINE") .. "\n"
		.. "Cargo slots: " .. tostring(minCarry) .. "-" .. tostring(maxCarry) .. "\n"
		.. routeLine .. "\n"
		.. depotLine .. "\n"
		.. priorityLine
		.. "\n\n<font color=\"#74CDFF\"><b>AVAILABLE CONTRACTS</b></font>\n"
		.. available
		.. "\n\n<font color=\"#74CDFF\"><b>ACTIVE DELIVERIES</b></font>\n"
		.. active
end

local function render(payload)
	if payload then
		lastPayload = payload
	end
	if not lastPayload then
		return
	end

	local playerData = lastPayload.player or {}
	local currentCash = tonumber(playerData.cash or playerData.money or 0) or 0
	local phase = tostring(lastPayload.phase or lastPayload.currentPhase or "")
	if hasSeenCashBaseline and currentCash > lastKnownCash and (phase == "DeliveryOutcome" or phase == "SystemEvolution") then
		task.spawn(animateCompletionPayout, lastKnownCash, currentCash)
	end
	lastKnownCash = currentCash
	hasSeenCashBaseline = true

	local sections = {
		formatPhase(lastPayload),
		formatEvents(lastPayload),
		formatPlayerSection(lastPayload),
		formatTowns(lastPayload),
		formatMVPStatus(lastPayload),
	}

	mainLabel.Text = table.concat(sections, "\n\n")
	setMainHUDVisibility(lastPayload)
end

local function showToast(message)
	table.insert(notifyQueue, message)
	if showingToast then
		return
	end
	showingToast = true

	while #notifyQueue > 0 do
		local msg = table.remove(notifyQueue, 1)
		toastLabel.Text = "<b>NOTICE</b>\n" .. tostring(msg)
		toastLabel.Visible = true
		task.wait(2.2)
		toastLabel.Visible = false
		task.wait(0.15)
	end

	showingToast = false
end

local function parsePickIndexes(rawMessage, contractsCount)
	local indexes = {}
	local seen = {}

	for numberText in string.gmatch(rawMessage, "%d+") do
		local idx = tonumber(numberText)
		if idx and idx >= 1 and idx <= contractsCount and not seen[idx] then
			seen[idx] = true
			table.insert(indexes, idx)
		end
	end

	return indexes
end

applyHUDStyling()

UpdateUI.OnClientEvent:Connect(function(payload)
	render(payload)
end)

Notify.OnClientEvent:Connect(function(message)
	showToast(tostring(message))
end)

player.Chatted:Connect(function(msg)
	local lowered = string.lower(msg)
	if string.sub(lowered, 1, 6) == "/route" then
		local town, routeId = msg:match("^/route%s+([%w_]+)%s+([%w_]+)")
		if not town or not routeId then
			showToast("Usage: /route TownName RouteId")
			return
		end
		SelectRoute:FireServer({ town = town, routeId = routeId })
		showToast("Route request sent.")
		return
	end

	if string.sub(lowered, 1, 8) == "/upgrade" then
		local tier, upgrade = msg:match("^/upgrade%s+([%w_]+)%s+([%w_]+)")
		if not tier or not upgrade then
			showToast("Usage: /upgrade TierName UpgradeName")
			return
		end
		BuyUpgrade:FireServer({ tier = tier, upgrade = upgrade })
		showToast("Upgrade purchase request sent.")
		return
	end

	if lowered == "/contracts" or lowered == "/dispatch" then
		RequestContracts:FireServer()
		showToast("Requested contracts from server.")
		return
	end

	if string.sub(lowered, 1, 5) ~= "/pick" then
		return
	end

	if not lastPayload or not lastPayload.contracts then
		showToast("No contract data yet.")
		return
	end

	local contracts = lastPayload.contracts
	if #contracts == 0 then
		showToast("No available contracts.")
		return
	end

	local minCarry, maxCarry = getCarryLimits(lastPayload)
	local indexes = parsePickIndexes(lowered, #contracts)

	if #indexes < minCarry then
		showToast(string.format("Pick at least %d contracts. Example: /pick 1 3", minCarry))
		return
	end

	if #indexes > maxCarry then
		showToast(string.format("You can only pick up to %d contracts.", maxCarry))
		return
	end

	local picked = {}
	for _, idx in ipairs(indexes) do
		table.insert(picked, contracts[idx])
	end

	PickContracts:FireServer(picked)
	showToast(string.format("Sent %d contract pick(s) to server.", #picked))
end)