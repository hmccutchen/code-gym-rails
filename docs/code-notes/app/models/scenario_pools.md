# `ScenarioPools`

The settings a day's scenarios are dressed in, one pool per flavor `DailyPlan` rolls. They are domain data, so they moved off `AiService` (#431). `GenerationPrompt` reads them.

## `GENERAL_DOMAINS`

Scenario dressing only, never tagged as a concept.
`legacy_graphql_maintenance` must never appear as a concept value.

## `ALL`

A spec holds these keys equal to `DailyPlan::SCENARIO_FLAVOR_WEIGHTS`' keys, so
every flavor that can be rolled has a pool.
