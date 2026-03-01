# Frontier Dispatch MVP

## Core Loop
1. Morning Dispatch (choose contracts)
2. Route Strategy (pick route)
3. Travel + Dynamic Events
4. Delivery Outcome (on-time vs late impact)
5. System Evolution (upgrades + scaling complexity)

## MVP Scope (Must Have)
- 3 towns:
  - Tombstone (desert): water, food
  - Deadwood (mountain): food, medicine, tools
  - Dodge City (main city): gold
- 5 resources: Food, Medicine, Tools, Gold, Water
- Contracts per day shown: 4-6
- Carry limit per run: 2-3
- 2 route options per town
- 3 random event types:
  - Dust storm
  - Broken bridge
  - Bandits
- 2 automation/visibility upgrades:
  - Visible demand board
  - Satisfaction meter

## Design Intent
- Before upgrades: player reacts to problems.
- After upgrades: player anticipates and adapts proactively.
- Progression shifts from manual dispatching to strategic logistics management.

## Source Of Truth In Code
- Runtime values are defined in `src/shared/GameConfig.luau`.
- If gameplay balance changes, update both this doc and `GameConfig` together.
