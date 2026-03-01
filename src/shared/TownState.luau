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
		HasTelegraph = false,
		AvailableContracts = {},
		ActiveContracts = {},
		ActiveEvent = nil, -- string or table
		BlockedTowns = {}, -- [towname] = unblockedTime
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
	return true, string.format("Accepted %d contract(s).", #data.ActiveContracts)
end

function TownState.DeliverAtTown(player, townName)
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

	for _, contract in ipairs(data.ActiveContracts) do
		if contract.Town == townName then
			table.insert(delivered, contract)
			payoutTotal += tonumber(contract.Payout) or 0

			local resource = contract.Resource
			if resource and town.Demand[resource] ~= nil then
				town.Demand[resource] = math.max(0, town.Demand[resource] - 10)
			end
		else
			table.insert(remaining, contract)
		end
	end

	if #delivered == 0 then
		return false, "No active contract for this town.", {}
	end

	data.ActiveContracts = remaining
	data.Score += #delivered
	data.Cash += payoutTotal
	town.Stability = clamp(town.Stability + 5, 0, 100)
	town.Trust = clamp(town.Trust + 4, 0, 100)
	town.Population = clamp(town.Population + 1, 0, 999999)

	return true, string.format("Delivered %d contract(s) to %s for $%d.", #delivered, townName, payoutTotal), delivered
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