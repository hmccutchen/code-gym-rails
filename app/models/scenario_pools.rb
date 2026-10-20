module ScenarioPools
  GENERAL_DOMAINS = %w[
    background_job_processing api_versioning_and_deprecation
    activerecord_query_construction component_state_management
    data_export_and_reporting webhook_delivery rate_limiting
    multi_tenant_data_isolation legacy_graphql_maintenance
  ].freeze

  EVERYDAY_DOMAINS = %w[
    shared_grocery_list recipe_box_and_meal_planner gym_workout_log
    library_book_checkout pet_adoption_listings household_chore_rota
    book_club_reading_list plant_watering_reminders event_rsvp_list
    personal_savings_goals
  ].freeze

  LEGACY_GRAPHQL_GUIDANCE =
    "Use a legacy GraphQL maintenance scenario (e.g. \"a legacy GraphQL layer needs a fix\") only rarely — " \
    "at most roughly 1 in every 8-10 sessions — purely as scenario framing, never as the tagged concept.".freeze

  ALL = {
    general: {
      domains:    GENERAL_DOMAINS,
      intro:      "real, job-adjacent flavors",
      adaptation: "a Rails day's \"component state management\" becomes a service/controller state concern instead",
      rule:       nil,
      legacy:     LEGACY_GRAPHQL_GUIDANCE
    },
    everyday: {
      domains:    EVERYDAY_DOMAINS,
      intro:      "everyday settings people already know from daily life",
      adaptation: "a Rails day's \"shared grocery list\" is the model and controller that store and update the list",
      rule:       "Keep the setting's own words plain and familiar: no business back-office terms such as invoices, " \
                  "ledgers, tenants, CSV exports or webhooks, and solving a section must never require knowing how " \
                  "a company's internal systems work.",
      legacy:     nil
    }
  }.freeze
end
