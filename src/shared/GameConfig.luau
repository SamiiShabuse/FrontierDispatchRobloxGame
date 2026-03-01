local GameConfig = {}

GameConfig.GameName = "Frontier Dispatch"
GameConfig.ConfigVersion = "mvp-v1"

-- Keep the core game loop visible to all systems.
GameConfig.LoopPhases = {
	"MorningDispatch",
	"RouteStrategy",
	"TravelDynamicEvents",
	"DeliveryOutcome",
	"SystemEvolution",
}

-- Source of truth for MVP scope.
GameConfig.MVP = {
	ContractsShownPerDay = { Min = 4, Max = 6 },
	CarryLimit = { Min = 2, Max = 3 },
	Towns = 3,
	RouteOptionsPerTown = 2,
	RandomEventTypes = 3,
	AutomationUpgrades = 2, -- visible demand + satisfaction meter
}

GameConfig.Resources = {
	"Food",
	"Medicine",
	"Tools",
	"Gold",
	"Water",
}

GameConfig.Towns = {
	Tombstone = {
		DisplayName = "Tombstone",
		Biome = "Desert",
		PrimaryDemand = { "Water", "Food" },
		BaseStability = 60,
		BaseTrust = 50,
		BasePopulation = 120,
		RouteOptions = {
			{
				Id = "DesertShortcut",
				DisplayName = "Desert Shortcut",
				Risk = "Medium",
				TravelTime = 0.85,
				Notes = "Faster, harsher weather.",
			},
			{
				Id = "MainRoadSouth",
				DisplayName = "Main Road",
				Risk = "Low",
				TravelTime = 1.10,
				Notes = "Reliable but slower.",
			},
		},
	},
	Deadwood = {
		DisplayName = "Deadwood",
		Biome = "Mountain",
		PrimaryDemand = { "Food", "Medicine", "Tools" },
		BaseStability = 55,
		BaseTrust = 45,
		BasePopulation = 95,
		RouteOptions = {
			{
				Id = "MountainPass",
				DisplayName = "Mountain Pass",
				Risk = "High",
				TravelTime = 0.80,
				Notes = "Fast but high chance of disruptions.",
			},
			{
				Id = "ValleyRoad",
				DisplayName = "Valley Road",
				Risk = "Low",
				TravelTime = 1.15,
				Notes = "Longer trip, safer roads.",
			},
		},
	},
	DodgeCity = {
		DisplayName = "Dodge City",
		Biome = "MainCity",
		PrimaryDemand = { "Gold" },
		BaseStability = 70,
		BaseTrust = 55,
		BasePopulation = 160,
		RouteOptions = {
			{
				Id = "RailAdjRoad",
				DisplayName = "Trade Road",
				Risk = "Medium",
				TravelTime = 0.95,
				Notes = "Balanced route for regular runs.",
			},
			{
				Id = "OldBridgeRoute",
				DisplayName = "Old Bridge",
				Risk = "High",
				TravelTime = 0.75,
				Notes = "Fastest path but fragile bridge.",
			},
		},
	},
}

GameConfig.Contracts = {
	ShownPerDayMin = 4,
	ShownPerDayMax = 6,
	CarryLimitMin = 2,
	CarryLimitMax = 3,
	DeadlineHoursMin = 8,
	DeadlineHoursMax = 20,
	ContractHourSeconds = 12, -- gameplay time scale for MVP
	UrgencyLevels = { "Low", "Medium", "High", "Critical" },
	LatePayoutMultiplier = 0.6,
	LateScorePenaltyPerContract = 1,
	Payout = {
		Min = 40,
		Max = 140,
		HighUrgencyMultiplier = 1.35,
		RiskMultiplier = 1.20,
	},
	OutcomeImpact = {
		OnTime = {
			Stability = 8,
			Trust = 6,
			Population = 2,
			DemandReduction = 10,
		},
		Late = {
			Stability = -10,
			Trust = -8,
			Population = -1,
			DemandIncrease = 12,
		},
	},
}

GameConfig.DynamicEvents = {
	TickIntervalMin = 10,
	TickIntervalMax = 20,
	BaseChancePerTrip = 0.35,
	Types = {
		DustStorm = {
			DisplayName = "Dust Storm",
			ChanceWeight = 0.40,
			SpeedMultiplier = 0.55,
			DurationSeconds = 10,
			Description = "Reduces movement speed during travel.",
		},
		BrokenBridge = {
			DisplayName = "Broken Bridge",
			ChanceWeight = 0.30,
			BlockDurationSeconds = 45,
			ForcedReroute = true,
			Description = "Bridge collapses and forces reroute.",
		},
		Bandits = {
			DisplayName = "Bandit Threat",
			ChanceWeight = 0.30,
			TimePenaltySeconds = 15,
			PayoutLossPercent = 0.15,
			Description = "Travel delay and possible payout loss.",
		},
	},
}

GameConfig.TownSystems = {
	DemandTickInterval = 10,
	BaseDemandIncreasePerTick = 1,
	DeliveryDemandReduction = 8,
	StatBounds = {
		Min = 0,
		Max = 100,
	},
}

GameConfig.Upgrades = {
	Tier1Visibility = {
		DemandBoard = {
			Cost = 100,
			Effect = "Shows real-time demand by town/resource.",
		},
		SatisfactionMeter = {
			Cost = 120,
			Effect = "Shows trust/stability trend for each town.",
		},
	},
	Tier2Automation = {
		AutoRouteSuggestions = {
			Cost = 180,
			Effect = "Suggests safer or faster routes by priority.",
		},
		PriorityDispatch = {
			Cost = 220,
			Effect = "Highlights contracts with biggest impact risk.",
		},
	},
	Tier3Infrastructure = {
		RailroadHub = {
			Cost = 320,
			Effect = "Allows partial cargo transfer and time savings.",
		},
		ReinforcedBridges = {
			Cost = 260,
			Effect = "Reduces broken bridge event chance.",
		},
		RegionalDepots = {
			Cost = 300,
			Effect = "Increases carry limit and dispatch flexibility.",
		},
	},
}

GameConfig.Progression = {
	ComplexityIncreasePerDay = 0.05,
	PopulationGrowthOnSuccess = 1,
	DemandGrowthPerPopulationStep = 0.2,
	RoadStrainGrowthPerDay = 0.03,
}

GameConfig.Depot = {
	Names = { "Depot", "DispatchDepot" },
	DropZoneNames = { "DropZone", "DepotDropZone", "DispatchZone" },
}

return GameConfig