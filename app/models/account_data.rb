# Design notes: docs/code-notes/app/models/account_data.md
module AccountData
  KINDS = %i[delete nullify give_back_seat delete_unfinished cascades keep].freeze

  Fate = Data.define(:kind, :columns, :rows, :reason) do
    def self.of(kind, reason, columns: [], rows: nil) = new(kind: kind, columns: columns, rows: rows, reason: reason)
  end

  def self.owned(model) = ->(user) { model.where(user_id: user.id) }

  # Deletion runs in this order, so a row goes before the row its foreign key points at.
  FATES = {
    "review_follow_ups" => Fate.of(:delete, "The person's questions about a review and the answers they got.",
      columns: %w[daily_response_id], rows: ->(user) { ReviewFollowUp.where(daily_response_id: DailyResponse.where(user_id: user.id).select(:id)) }),
    "judge_solves" => Fate.of(:delete, "Judge passes on the person's own sets; synthetic rows have no user and stay.",
      columns: %w[user_id daily_exercise_id], rows: ->(user) { JudgeSolve.where(user_id: user.id).or(JudgeSolve.where(daily_exercise_id: DailyExercise.where(user_id: user.id).select(:id))) }),
    "duck_threads" => Fate.of(:delete, "The person's rubber-duck conversations.", columns: %w[user_id daily_exercise_id], rows: owned(DuckThread)),
    "daily_responses" => Fate.of(:delete, "The person's answers, ratings and reviews.", columns: %w[user_id daily_exercise_id], rows: owned(DailyResponse)),
    "daily_exercises" => Fate.of(:delete, "The sets generated for the person.", columns: %w[user_id], rows: owned(DailyExercise)),
    "push_subscriptions" => Fate.of(:delete, "The person's browser endpoints and push keys.", columns: %w[user_id], rows: owned(PushSubscription)),
    "api_usages" => Fate.of(:delete, "The person's provider calls; spend totals lose these rows.", columns: %w[user_id], rows: owned(ApiUsage)),
    "concept_masteries" => Fate.of(:delete, "The person's standing on each concept.", columns: %w[user_id], rows: owned(ConceptMastery)),
    "featured_concepts" => Fate.of(:delete, "The concept picked for the person each week.", columns: %w[user_id], rows: owned(FeaturedConcept)),
    "level_suggestion_events" => Fate.of(:delete, "The person's level changes and dismissals.", columns: %w[user_id], rows: owned(LevelSuggestionEvent)),
    "daily_kind_swaps" => Fate.of(:delete, "The person's daily kind swaps.", columns: %w[user_id], rows: owned(DailyKindSwapEvent)),
    "concept_references" => Fate.of(:delete, "The person's concept write-ups; every row has an owner.",
      columns: %w[user_id], rows: owned(ConceptReference)),
    "recognition_guides" => Fate.of(:delete, "The person's recognition guides; every row has an owner.",
      columns: %w[user_id], rows: owned(RecognitionGuide)),
    "suggested_concepts" => Fate.of(:nullify, "The concept stays for the team; only who reviewed it is forgotten.",
      columns: %w[reviewed_by_id], rows: ->(user) { SuggestedConcept.where(reviewed_by_id: user.id) }),
    "invite_codes" => Fate.of(:give_back_seat, "The code is shared, so it stays; the seat the person took is given back."),
    "solid_cache_entries" => Fate.of(:keep, "Entries expire through config/cache.yml's max_age."),
    "solid_queue_jobs" => Fate.of(:delete_unfinished, "Unfinished jobs naming the person go now; finished ones are cleared after a day."),
    "solid_queue_ready_executions" => Fate.of(:cascades, "Goes with its job row through the foreign key's cascade."),
    "solid_queue_scheduled_executions" => Fate.of(:cascades, "Goes with its job row through the foreign key's cascade."),
    "solid_queue_blocked_executions" => Fate.of(:cascades, "Goes with its job row through the foreign key's cascade."),
    "solid_queue_failed_executions" => Fate.of(:cascades, "Goes with its job row through the foreign key's cascade."),
    "solid_queue_claimed_executions" => Fate.of(:cascades, "A running job is left to finish; the cleanup task clears it after a day."),
    "users" => Fate.of(:delete, "The account itself, last, once nothing points at it.", columns: %w[email], rows: ->(user) { User.where(id: user.id) })
  }.freeze
end
