local TownState = {}

TownState.Towns = {}
TownState.PlayerData = {}

function TownState.InitTown(townName, resources)
	TownState.Towns[townName] = {
		Demand = {},
		Stability = 60,
		Trust = 50,
		Population = 100,
	}

	for _, resource in ipairs(resources) do
		TownState.Towns[townName].Demand[resource] = 0
	end
end

function TownState.InitPlayer(player)
	TownState.PlayerData[player] = {
		Score = 0,
		Cash = 0,
		Money = 0,
		HasTelegraph = false,
		AvailableContracts = {},
		ActiveContracts = {},
		ActiveEvent = nil, -- string or table
		BlockedTowns = {}, -- [towname] = unblockedTime
		Day = 1,
		CurrentPhase = "MorningDispatch",
		Upgrades = {},
		SelectedRoute = nil,
		CarryLimit = 3,
		ReadyForDepot = false,
		LastEventText = nil,
		ActiveEvents = {},
	}
end

function TownState.RemovePlayer(player)
	TownState.PlayerData[player] = nil
end

function TownState.GetPlayerData(player)
	return TownState.PlayerData[player]
end

function TownState.SetAvailableContracts(player, contracts)
	local data = TownState.PlayerData[player]
	if not data then
		return false
	end
	data.AvailableContracts = contracts or {}
	return true
end

function TownState.ApplyLoadedPlayerData(player, loadedData)
	local data = TownState.PlayerData[player]
	if not data then
		return false
	end
	if type(loadedData) ~= "table" then
		return false
	end

	data.Score = tonumber(loadedData.Score) or data.Score
	data.Cash = tonumber(loadedData.Cash) or data.Cash
	data.Money = tonumber(loadedData.Cash) or data.Cash
	data.HasTelegraph = loadedData.HasTelegraph == true
	data.Day = tonumber(loadedData.Day) or data.Day
	data.CarryLimit = tonumber(loadedData.CarryLimit) or data.CarryLimit
	data.Upgrades = type(loadedData.Upgrades) == "table" and loadedData.Upgrades or data.Upgrades
	return true
end

function TownState.ExportPlayerSaveData(player)
	local data = TownState.PlayerData[player]
	if not data then
		return nil
	end

	return {
		Score = data.Score or 0,
		Cash = data.Cash or 0,
		HasTelegraph = data.HasTelegraph == true,
		Day = data.Day or 1,
		CarryLimit = data.CarryLimit or 3,
		Upgrades = data.Upgrades or {},
	}
end

local function shallowCopyArray(list)
	local out = {}
	for i, value in ipairs(list) do
		out[i] = value
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

function TownState.SelectContracts(player, selectedContracts, minCarry, maxCarry)
	local data = TownState.PlayerData[player]
	if not data then
		return false, "Player not initialized."
	end

	local selected = selectedContracts or {}
	if #selected < minCarry then
		return false, string.format("Pick at least %d contracts.", minCarry)
	end
	if #selected > maxCarry then
		return false, string.format("You can only pick up to %d contracts.", maxCarry)
	end

	data.ActiveContracts = shallowCopyArray(selected)
	for _, contract in ipairs(data.ActiveContracts) do
		contract.Status = contract.Status or "Active"
	end
	data.ReadyForDepot = false
	return true, string.format("Accepted %d contract(s).", #data.ActiveContracts)
end

function TownState.RefreshContractDeadlines(player, nowTimestamp)
	local data = TownState.PlayerData[player]
	if not data then
		return 0
	end
	local now = nowTimestamp or os.time()
	local lateCount = 0
	for _, contract in ipairs(data.ActiveContracts) do
		if contract.DueAt and now > contract.DueAt then
			contract.IsLate = true
			contract.Status = "Late"
			lateCount += 1
		elseif not contract.IsLate then
			contract.Status = "Active"
		end
	end
	return lateCount
end

function TownState.ExpireLateContracts(player, nowTimestamp, lateImpact, lateFeePerContract)
	local data = TownState.PlayerData[player]
	if not data then
		return {}
	end

	local now = nowTimestamp or os.time()
	local impact = lateImpact or {}
	local expired = {}
	local kept = {}

	for _, contract in ipairs(data.ActiveContracts) do
		if contract.DueAt and now > contract.DueAt then
			contract.Status = "Failed"
			contract.IsLate = true
			table.insert(expired, contract)

			local town = TownState.Towns[contract.Town]
			if town then
				town.Stability = clamp(town.Stability + (tonumber(impact.Stability) or 0), 0, 100)
				town.Trust = clamp(town.Trust + (tonumber(impact.Trust) or 0), 0, 100)
				town.Population = clamp(town.Population + (tonumber(impact.Population) or 0), 0, 999999)

				local resource = contract.Resource
				local demandIncrease = tonumber(impact.DemandIncrease) or 0
				if resource and town.Demand[resource] ~= nil then
					town.Demand[resource] = math.max(0, town.Demand[resource] + demandIncrease)
				end
			end
		else
			table.insert(kept, contract)
		end
	end

	if #expired > 0 then
		data.ActiveContracts = kept
		local fee = (tonumber(lateFeePerContract) or 0) * #expired
		data.Cash = math.max(0, (data.Cash or 0) - fee)
		data.Money = data.Cash
	end

	return expired
end

function TownState.DeliverAtTown(player, townName, options)
	local data = TownState.PlayerData[player]
	if not data then
		return false, "Player not initialized.", {}
	end

	local town = TownState.Towns[townName]
	if not town then
		return false, string.format("Unknown town '%s'.", tostring(townName)), {}
	end

	local delivered = {}
	local remaining = {}
	local payoutTotal = 0
	local onTimeCount = 0
	local lateCount = 0
	local opts = options or {}
	local now = tonumber(opts.Now) or os.time()
	local demandReduction = tonumber(opts.DemandReduction) or 10
	local latePayoutMultiplier = tonumber(opts.LatePayoutMultiplier) or 0.6
	local routeBonusMultiplier = tonumber(opts.RouteBonusMultiplier) or 1.0
	local onTimeImpact = opts.OnTimeImpact or {}
	local lateImpact = opts.LateImpact or {}

	for _, contract in ipairs(data.ActiveContracts) do
		if contract.Town == townName then
			local isLate = contract.IsLate == true or (contract.DueAt and now > contract.DueAt)
			contract.IsLate = isLate
			contract.Status = isLate and "LateDelivered" or "Delivered"
			table.insert(delivered, contract)

			local payout = tonumber(contract.Payout) or 0
			if isLate then
				payout = math.floor(payout * latePayoutMultiplier)
				lateCount += 1
			else
				payout = math.floor(payout * routeBonusMultiplier)
				onTimeCount += 1
			end
			contract.FinalPayout = payout
			payoutTotal += payout

			local resource = contract.Resource
			if resource and town.Demand[resource] ~= nil then
				local baseDelta = demandReduction
				local latePenaltyDelta = tonumber(lateImpact.DemandIncrease) or 0
				local onTimeBonusDelta = tonumber(onTimeImpact.DemandReduction) or 0
				local delta = isLate and -latePenaltyDelta or math.max(baseDelta, onTimeBonusDelta)
				town.Demand[resource] = math.max(0, town.Demand[resource] - delta)
			end
		else
			table.insert(remaining, contract)
		end
	end

	if #delivered == 0 then
		return false, "No active contract for this town.", {}
	end

	data.ActiveContracts = remaining
	data.Score += onTimeCount
	data.Score = math.max(0, data.Score - lateCount * (tonumber(opts.LateScorePenaltyPerContract) or 0))
	data.Cash += payoutTotal
	data.Money = data.Cash
	town.Stability = clamp(town.Stability + 5, 0, 100)
	town.Trust = clamp(town.Trust + 4, 0, 100)
	town.Population = clamp(town.Population + 1, 0, 999999)

	local stabilityOnTime = tonumber(onTimeImpact.Stability) or 0
	local trustOnTime = tonumber(onTimeImpact.Trust) or 0
	local popOnTime = tonumber(onTimeImpact.Population) or 0
	local stabilityLate = tonumber(lateImpact.Stability) or 0
	local trustLate = tonumber(lateImpact.Trust) or 0
	local popLate = tonumber(lateImpact.Population) or 0

	town.Stability = clamp(town.Stability + onTimeCount * stabilityOnTime + lateCount * stabilityLate, 0, 100)
	town.Trust = clamp(town.Trust + onTimeCount * trustOnTime + lateCount * trustLate, 0, 100)
	town.Population = clamp(town.Population + onTimeCount * popOnTime + lateCount * popLate, 0, 999999)

	if #data.ActiveContracts == 0 then
		data.ReadyForDepot = true
	end

	local detail = string.format("Delivered %d contract(s) to %s for $%d.", #delivered, townName, payoutTotal)
	if lateCount > 0 then
		detail ..= string.format(" (%d late)", lateCount)
	end

	return true, detail, delivered
end

function TownState.ExportTowns()
	local out = {}
	for townName, townData in pairs(TownState.Towns) do
		out[townName] = {
			Demand = {},
			Stability = townData.Stability,
			Trust = townData.Trust,
			Population = townData.Population,
		}
		for resource, amount in pairs(townData.Demand) do
			out[townName].Demand[resource] = amount
		end
	end
	return out
end

function TownState.GetUIPayload(player)
	local data = TownState.PlayerData[player]
	if not data then
		return {
			towns = TownState.ExportTowns(),
			contracts = {},
			activeContracts = {},
			player = {},
		}
	end

	return {
		phase = "MorningDispatch",
		towns = TownState.ExportTowns(),
		contracts = data.AvailableContracts,
		activeContracts = data.ActiveContracts,
		player = {
			score = data.Score,
			cash = data.Cash,
			hasTelegraph = data.HasTelegraph,
		},
	}
end

return TownState