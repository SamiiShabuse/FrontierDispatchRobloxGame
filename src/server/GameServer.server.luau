local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local function getModule(moduleName)
	local shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 5)
	if shared then
		local fromShared = shared:FindFirstChild(moduleName)
		if fromShared and fromShared:IsA("ModuleScript") then
			return require(fromShared)
		end
	end

	local fromRoot = ReplicatedStorage:FindFirstChild(moduleName)
	if fromRoot and fromRoot:IsA("ModuleScript") then
		return require(fromRoot)
	end

	error(("Missing module '%s' in ReplicatedStorage.Shared or ReplicatedStorage root."):format(moduleName))
end

local GameConfig = getModule("GameConfig")
local TownState = getModule("TownState")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local function ensureRemote(name)
	local remote = remotes:FindFirstChild(name)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	if remote then
		remote:Destroy()
	end
	remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotes
	return remote
end

local UpdateUI = ensureRemote("UpdateUI")
local Notify = ensureRemote("Notify")
local PickContracts = ensureRemote("PickContracts")
local SelectRoute = ensureRemote("SelectRoute")
local BuyUpgrade = ensureRemote("BuyUpgrade")
local RequestContracts = ensureRemote("RequestContracts")

local serverTick = 0
local touchDebounce = {}

local CONTRACTS_CFG = GameConfig.Contracts or {}
local EVENTS_CFG = GameConfig.DynamicEvents or {}
local TOWN_SYSTEMS_CFG = GameConfig.TownSystems or {}

local DEMAND_TICK_INTERVAL = TOWN_SYSTEMS_CFG.DemandTickInterval or 10
local BASE_DEMAND_INCREASE = TOWN_SYSTEMS_CFG.BaseDemandIncreasePerTick or 1
local CARRY_MIN = CONTRACTS_CFG.CarryLimitMin or 2
local CARRY_MAX = CONTRACTS_CFG.CarryLimitMax or 3
local UPGRADE_TELEGRAPH_COST = (((GameConfig.Upgrades or {}).Tier1Visibility or {}).DemandBoard or {}).Cost or 100

local function getTownFolder()
	local fromMap = Workspace:FindFirstChild("Map")
	if fromMap then
		local mapTowns = fromMap:FindFirstChild("Towns")
		if mapTowns and mapTowns:IsA("Folder") then
			return mapTowns
		end
	end

	local towns = Workspace:FindFirstChild("Towns")
	if towns and towns:IsA("Folder") then
		return towns
	end

	return nil
end

local function listTownNames()
	local names = {}
	for townName, _ in pairs(GameConfig.Towns or {}) do
		table.insert(names, townName)
	end
	table.sort(names)
	return names
end

local function copyArray(input)
	local out = {}
	for i, item in ipairs(input or {}) do
		out[i] = item
	end
	return out
end

local function clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

local function getPlayerData(player)
	local data = TownState.GetPlayerData(player)
	if not data then
		TownState.InitPlayer(player)
		data = TownState.GetPlayerData(player)
	end
	if not data then
		return nil
	end

	data.Day = data.Day or 1
	data.CurrentPhase = data.CurrentPhase or "MorningDispatch"
	data.Upgrades = data.Upgrades or {}
	data.SelectedRoute = data.SelectedRoute or nil
	data.LastEventText = data.LastEventText or nil
	data.ActiveEvents = data.ActiveEvents or {}
	data.CarryLimit = data.CarryLimit or CARRY_MAX
	data.Money = data.Money or data.Cash or 0
	data.Cash = data.Cash or data.Money or 0

	return data
end

local function weightedRandomEventType()
	local eventTypes = EVENTS_CFG.Types or {}
	local rollTable = {}
	local totalWeight = 0

	for eventName, eventData in pairs(eventTypes) do
		local weight = tonumber(eventData.ChanceWeight) or 0
		if weight > 0 then
			totalWeight += weight
			table.insert(rollTable, { Name = eventName, Weight = weight })
		end
	end

	if totalWeight <= 0 or #rollTable == 0 then
		return "DustStorm", {}
	end

	local roll = math.random() * totalWeight
	local running = 0
	for _, entry in ipairs(rollTable) do
		running += entry.Weight
		if roll <= running then
			return entry.Name, eventTypes[entry.Name] or {}
		end
	end

	local fallback = rollTable[#rollTable].Name
	return fallback, eventTypes[fallback] or {}
end

local function getHighestDemand()
	local highestTown, highestResource, highestValue = nil, nil, -1
	for townName, townData in pairs(TownState.Towns) do
		for resourceName, value in pairs(townData.Demand or {}) do
			if value > highestValue then
				highestTown = townName
				highestResource = resourceName
				highestValue = value
			end
		end
	end
	return highestTown, highestResource
end

local function pickTownNameForContract()
	local townNames = listTownNames()
	if #townNames == 0 then
		return "Tombstone"
	end

	local topTown = getHighestDemand()
	if topTown and math.random() < 0.55 then
		return topTown
	end

	return townNames[math.random(1, #townNames)]
end

local function pickResourceForTown(townName)
	local townConfig = (GameConfig.Towns or {})[townName] or {}
	local pool = copyArray(townConfig.PrimaryDemand or {})
	if #pool == 0 then
		pool = copyArray(GameConfig.Resources or {})
	end
	if #pool == 0 then
		return "Food"
	end
	return pool[math.random(1, #pool)]
end

local function pickUrgency()
	local urgencies = CONTRACTS_CFG.UrgencyLevels or { "Low", "Medium", "High" }
	return urgencies[math.random(1, #urgencies)]
end

local function urgencyMultiplier(urgency)
	if urgency == "Critical" then
		return 1.45
	elseif urgency == "High" then
		return 1.25
	elseif urgency == "Medium" then
		return 1.10
	end
	return 1.0
end

local function routeRiskMultiplier(townName)
	local townConfig = (GameConfig.Towns or {})[townName]
	if not townConfig or not townConfig.RouteOptions then
		return 1.0
	end
	local route = townConfig.RouteOptions[math.random(1, #townConfig.RouteOptions)]
	local risk = tostring(route.Risk or "Medium")
	if risk == "High" then
		return 1.20
	elseif risk == "Low" then
		return 1.0
	end
	return 1.1
end

local function generateContractsForPlayer(player)
	local pdata = getPlayerData(player)
	if not pdata then
		return
	end

	local minShown = CONTRACTS_CFG.ShownPerDayMin or 4
	local maxShown = CONTRACTS_CFG.ShownPerDayMax or 6
	local count = math.random(minShown, maxShown)
	local minPayout = (CONTRACTS_CFG.Payout and CONTRACTS_CFG.Payout.Min) or 40
	local maxPayout = (CONTRACTS_CFG.Payout and CONTRACTS_CFG.Payout.Max) or 120
	local minDeadline = CONTRACTS_CFG.DeadlineHoursMin or 8
	local maxDeadline = CONTRACTS_CFG.DeadlineHoursMax or 20

	local contracts = {}
	for i = 1, count do
		local townName = pickTownNameForContract()
		local urgency = pickUrgency()
		local basePayout = math.random(minPayout, maxPayout)
		local payout = math.floor(basePayout * urgencyMultiplier(urgency) * routeRiskMultiplier(townName))
		local contract = {
			Id = string.format("%d-%d-%d", os.time(), player.UserId, i),
			Town = townName,
			Resource = pickResourceForTown(townName),
			Urgency = urgency,
			Payout = payout,
			Deadline = math.random(minDeadline, maxDeadline),
		}
		table.insert(contracts, contract)
	end

	pdata.ActiveContracts = {}
	pdata.SelectedRoute = nil
	pdata.CurrentPhase = "MorningDispatch"
	TownState.SetAvailableContracts(player, contracts)
	Notify:FireClient(player, "Pick contracts at the depot. Use /pick 1 2")
end

local function getPriorityForPlayer(pdata)
	local townName, resourceName = getHighestDemand()
	if not pdata.HasTelegraph or not townName or not resourceName then
		return nil
	end
	return {
		town = townName,
		resource = resourceName,
	}
end

local function buildPayloadFor(player)
	local pdata = getPlayerData(player)
	local payload = TownState.GetUIPayload(player)

	payload.tick = serverTick
	payload.phase = pdata and pdata.CurrentPhase or "MorningDispatch"
	payload.day = pdata and pdata.Day or 1
	payload.events = {}
	payload.lastEvent = pdata and pdata.LastEventText or nil
	payload.objective = "Pick contracts at the depot."

	if pdata then
		if payload.phase == "RouteStrategy" then
			payload.objective = "Choose route and deliver to destination DropZone."
		elseif payload.phase == "TravelDynamicEvents" then
			payload.objective = "Stay on route and react to events."
		elseif payload.phase == "DeliveryOutcome" then
			payload.objective = "Delivery complete. Return to depot for next dispatch."
		end

		payload.player = payload.player or {}
		payload.player.score = pdata.Score or 0
		payload.player.cash = pdata.Cash or pdata.Money or 0
		payload.player.hasTelegraph = pdata.HasTelegraph or false
		payload.player.priority = getPriorityForPlayer(pdata)
		payload.player.carryLimit = pdata.CarryLimit or CARRY_MAX
		payload.player.minCarryLimit = CARRY_MIN
		payload.player.upgrades = pdata.Upgrades or {}
		payload.player.route = pdata.SelectedRoute
		payload.blockedTowns = pdata.BlockedTowns or {}

		for eventName, _ in pairs(pdata.ActiveEvents or {}) do
			table.insert(payload.events, eventName)
		end
	end

	return payload
end

local function pushUI(player)
	UpdateUI:FireClient(player, buildPayloadFor(player))
end

local function broadcast()
	serverTick += 1
	for _, player in ipairs(Players:GetPlayers()) do
		pushUI(player)
	end
end

local function canDeliverToTown(pdata, townName)
	local blockedUntil = (pdata.BlockedTowns or {})[townName]
	if not blockedUntil then
		return true
	end
	if os.clock() >= blockedUntil then
		pdata.BlockedTowns[townName] = nil
		return true
	end
	return false
end

local function unlockTelegraphIfEarned(player, pdata)
	if pdata.HasTelegraph then
		return
	end
	if (pdata.Score or 0) >= UPGRADE_TELEGRAPH_COST then
		pdata.HasTelegraph = true
		pdata.Upgrades.DemandBoard = true
		Notify:FireClient(player, "Telegraph Dispatch unlocked: demand visibility online.")
	end
end

local function touchKey(player, townName)
	return tostring(player.UserId) .. "::" .. townName
end

local function touchAllowed(player, townName)
	local key = touchKey(player, townName)
	local now = os.clock()
	local nextOk = touchDebounce[key] or 0
	if now < nextOk then
		return false
	end
	touchDebounce[key] = now + 0.9
	return true
end

local function playerFromHit(hit)
	if not hit then
		return nil
	end
	local parent = hit.Parent
	if not parent then
		return nil
	end
	local player = Players:GetPlayerFromCharacter(parent)
	if player then
		return player
	end
	if parent.Parent then
		return Players:GetPlayerFromCharacter(parent.Parent)
	end
	return nil
end

local function findDropZone(model)
	if not model then
		return nil
	end
	local direct = model:FindFirstChild("DropZone")
	if direct and direct:IsA("BasePart") then
		return direct
	end

	local dropZoneModel = model:FindFirstChild("DropZoneModel")
	if dropZoneModel then
		local nested = dropZoneModel:FindFirstChild("DropZone")
		if nested and nested:IsA("BasePart") then
			return nested
		end
	end

	local deep = model:FindFirstChild("DropZone", true)
	if deep and deep:IsA("BasePart") then
		return deep
	end
	return nil
end

local function onDropZoneTouched(townName, hit)
	local player = playerFromHit(hit)
	if not player then
		return
	end
	if not touchAllowed(player, townName) then
		return
	end

	local pdata = getPlayerData(player)
	if not pdata then
		return
	end

	if not canDeliverToTown(pdata, townName) then
		Notify:FireClient(player, ("Bridge is out. %s is blocked for now."):format(townName))
		pushUI(player)
		return
	end

	local ok, message, delivered = TownState.DeliverAtTown(player, townName)
	Notify:FireClient(player, message)

	if ok then
		pdata.CurrentPhase = "DeliveryOutcome"
		unlockTelegraphIfEarned(player, pdata)

		if #delivered > 0 and #pdata.ActiveContracts == 0 then
			pdata.Day += 1
			generateContractsForPlayer(player)
			Notify:FireClient(player, "All deliveries complete. New contracts are now available.")
		else
			pdata.CurrentPhase = "TravelDynamicEvents"
		end
	end

	pushUI(player)
end

local boundDropzones = {}

local function bindTownDropZone(townModel)
	local townName = townModel.Name
	local dropZone = findDropZone(townModel)
	if not dropZone then
		warn(("No DropZone found for town '%s'."):format(townName))
		return
	end
	if boundDropzones[dropZone] then
		return
	end
	boundDropzones[dropZone] = true
	dropZone.Touched:Connect(function(hit)
		onDropZoneTouched(townName, hit)
	end)
end

local function ensureTownInitialized(townName)
	if TownState.Towns[townName] then
		return
	end

	local townConfig = (GameConfig.Towns or {})[townName] or {}
	local resources = copyArray(townConfig.PrimaryDemand or {})
	if #resources == 0 then
		resources = copyArray(GameConfig.Resources or {})
	end
	TownState.InitTown(townName, resources)
end

local function initializeTowns()
	for townName, townConfig in pairs(GameConfig.Towns or {}) do
		local resources = copyArray(townConfig.PrimaryDemand or {})
		if #resources == 0 then
			resources = copyArray(GameConfig.Resources or {})
		end
		TownState.InitTown(townName, resources)
	end

	local townFolder = getTownFolder()
	if not townFolder then
		warn("No Workspace towns folder found (expected Workspace.Map.Towns or Workspace.Towns).")
		return
	end

	for _, townModel in ipairs(townFolder:GetChildren()) do
		if townModel:IsA("Model") or townModel:IsA("Folder") then
			ensureTownInitialized(townModel.Name)
			bindTownDropZone(townModel)
		end
	end

	townFolder.ChildAdded:Connect(function(child)
		task.wait(0.05)
		if child:IsA("Model") or child:IsA("Folder") then
			ensureTownInitialized(child.Name)
			bindTownDropZone(child)
			broadcast()
		end
	end)
end

local function setPlayerSpeedMultiplier(player, multiplier, durationSeconds)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local original = humanoid.WalkSpeed
	humanoid.WalkSpeed = math.max(6, original * multiplier)
	task.delay(durationSeconds, function()
		if humanoid and humanoid.Parent then
			humanoid.WalkSpeed = original
		end
	end)
end

local function getRandomActiveTown(pdata)
	local contracts = pdata.ActiveContracts or {}
	if #contracts == 0 then
		return nil
	end
	local contract = contracts[math.random(1, #contracts)]
	return contract.Town
end

local function clearExpiredBlocks(pdata)
	for townName, blockedUntil in pairs(pdata.BlockedTowns or {}) do
		if os.clock() >= blockedUntil then
			pdata.BlockedTowns[townName] = nil
		end
	end
end

local function applyRandomEventToPlayer(player)
	local pdata = getPlayerData(player)
	if not pdata or #(pdata.ActiveContracts or {}) == 0 then
		return
	end

	clearExpiredBlocks(pdata)
	local eventName, eventData = weightedRandomEventType()
	local eventLabel = eventData.DisplayName or eventName
	pdata.CurrentPhase = "TravelDynamicEvents"
	pdata.LastEventText = eventLabel
	pdata.ActiveEvents[eventName] = true

	if pdata.HasTelegraph then
		Notify:FireClient(player, ("Telegraph alert: possible %s ahead."):format(eventLabel))
		task.wait(1.0)
	end

	if eventName == "DustStorm" then
		local mult = tonumber(eventData.SpeedMultiplier) or 0.6
		local duration = tonumber(eventData.DurationSeconds) or 10
		setPlayerSpeedMultiplier(player, mult, duration)
		Notify:FireClient(player, "Dust storm hit: movement slowed.")

		task.delay(duration, function()
			local current = TownState.GetPlayerData(player)
			if current then
				current.ActiveEvents[eventName] = nil
				pushUI(player)
			end
		end)

	elseif eventName == "Bandits" then
		local payoutLossPercent = tonumber(eventData.PayoutLossPercent) or 0.15
		local penalty = math.floor((pdata.Cash or 0) * payoutLossPercent)
		penalty = math.max(penalty, tonumber(eventData.TimePenaltySeconds) or 10)
		pdata.Cash = math.max(0, (pdata.Cash or 0) - penalty)
		pdata.Money = pdata.Cash
		Notify:FireClient(player, ("Bandits attacked: -$%d."):format(penalty))
		pdata.ActiveEvents[eventName] = nil

	elseif eventName == "BrokenBridge" then
		local townName = getRandomActiveTown(pdata)
		local blockDuration = tonumber(eventData.BlockDurationSeconds) or 45
		if townName then
			pdata.BlockedTowns[townName] = os.clock() + blockDuration
			Notify:FireClient(player, ("Bridge failure near %s. Route blocked briefly."):format(townName))
		end

		task.delay(blockDuration, function()
			local current = TownState.GetPlayerData(player)
			if current then
				current.ActiveEvents[eventName] = nil
				pushUI(player)
			end
		end)
	else
		pdata.ActiveEvents[eventName] = nil
	end
end

PickContracts.OnServerEvent:Connect(function(player, pickedContracts)
	local pdata = getPlayerData(player)
	if not pdata then
		return
	end
	if typeof(pickedContracts) ~= "table" then
		Notify:FireClient(player, "Invalid contract payload.")
		return
	end

	local ok, message = TownState.SelectContracts(player, pickedContracts, CARRY_MIN, pdata.CarryLimit or CARRY_MAX)
	if not ok then
		Notify:FireClient(player, message)
		pdata.CurrentPhase = "MorningDispatch"
		pushUI(player)
		return
	end

	pdata.CurrentPhase = "RouteStrategy"
	Notify:FireClient(player, message)
	Notify:FireClient(player, "Contracts locked. Choose a route and start driving.")
	pushUI(player)
end)

SelectRoute.OnServerEvent:Connect(function(player, payload)
	local pdata = getPlayerData(player)
	if not pdata then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	local townName = payload.town
	local routeId = payload.routeId
	if type(townName) ~= "string" or type(routeId) ~= "string" then
		Notify:FireClient(player, "Invalid route selection.")
		return
	end

	local townConfig = (GameConfig.Towns or {})[townName]
	local selectedRoute = nil
	for _, route in ipairs((townConfig and townConfig.RouteOptions) or {}) do
		if route.Id == routeId then
			selectedRoute = route
			break
		end
	end

	if not selectedRoute then
		Notify:FireClient(player, "Route not found.")
		return
	end

	pdata.SelectedRoute = {
		town = townName,
		routeId = routeId,
		displayName = selectedRoute.DisplayName or routeId,
		risk = selectedRoute.Risk or "Medium",
	}
	pdata.CurrentPhase = "TravelDynamicEvents"
	Notify:FireClient(player, ("Route selected: %s (%s risk)"):format(pdata.SelectedRoute.displayName, pdata.SelectedRoute.risk))
	pushUI(player)
end)

BuyUpgrade.OnServerEvent:Connect(function(player, payload)
	local pdata = getPlayerData(player)
	if not pdata or typeof(payload) ~= "table" then
		return
	end

	local tierName = payload.tier
	local upgradeName = payload.upgrade
	if type(tierName) ~= "string" or type(upgradeName) ~= "string" then
		return
	end

	local tier = (GameConfig.Upgrades or {})[tierName]
	local upgrade = tier and tier[upgradeName]
	if not upgrade then
		Notify:FireClient(player, "Upgrade not found.")
		return
	end

	local key = tierName .. "." .. upgradeName
	if pdata.Upgrades[key] then
		Notify:FireClient(player, "Upgrade already owned.")
		return
	end

	local cost = tonumber(upgrade.Cost) or 0
	local cash = pdata.Cash or 0
	if cash < cost then
		Notify:FireClient(player, ("Need $%d more for %s."):format(cost - cash, upgradeName))
		return
	end

	pdata.Cash = cash - cost
	pdata.Money = pdata.Cash
	pdata.Upgrades[key] = true
	pdata.Upgrades[upgradeName] = true
	Notify:FireClient(player, ("Upgrade purchased: %s"):format(upgradeName))
	pushUI(player)
end)

RequestContracts.OnServerEvent:Connect(function(player)
	local pdata = getPlayerData(player)
	if not pdata then
		return
	end
	if #(pdata.ActiveContracts or {}) > 0 then
		Notify:FireClient(player, "Finish active contracts first.")
		return
	end
	generateContractsForPlayer(player)
	pushUI(player)
end)

Players.PlayerAdded:Connect(function(player)
	TownState.InitPlayer(player)
	local pdata = getPlayerData(player)
	if not pdata then
		return
	end
	generateContractsForPlayer(player)
	pushUI(player)
end)

Players.PlayerRemoving:Connect(function(player)
	TownState.RemovePlayer(player)
	for key, _ in pairs(touchDebounce) do
		if string.find(key, tostring(player.UserId), 1, true) == 1 then
			touchDebounce[key] = nil
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(DEMAND_TICK_INTERVAL)
		for townName, townData in pairs(TownState.Towns) do
			local baseGrowth = BASE_DEMAND_INCREASE
			local townCfg = (GameConfig.Towns or {})[townName] or {}
			local priorityResources = {}
			for _, resource in ipairs(townCfg.PrimaryDemand or {}) do
				priorityResources[resource] = true
			end

			for resourceName, demandValue in pairs(townData.Demand or {}) do
				local growth = baseGrowth
				if priorityResources[resourceName] then
					growth += 1
				end
				townData.Demand[resourceName] = clamp(demandValue + growth, 0, 1000)
			end
		end
		broadcast()
	end
end)

task.spawn(function()
	while true do
		local minTick = EVENTS_CFG.TickIntervalMin or 10
		local maxTick = EVENTS_CFG.TickIntervalMax or 20
		task.wait(math.random(minTick, maxTick))
		for _, player in ipairs(Players:GetPlayers()) do
			applyRandomEventToPlayer(player)
		end
		broadcast()
	end
end)

task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			local pdata = TownState.GetPlayerData(player)
			if pdata then
				clearExpiredBlocks(pdata)
			end
		end
	end
end)

initializeTowns()
for _, player in ipairs(Players:GetPlayers()) do
	TownState.InitPlayer(player)
	generateContractsForPlayer(player)
	pushUI(player)
end

broadcast()