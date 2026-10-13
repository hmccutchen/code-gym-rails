module MetConceptHelpers
  # One submitted, reviewed set dated `date` whose only section showed `concept`, so the user has met it.
  def submit_set_showing(user, concept, date:, section: "code_review", rung: "senior", ai: "developing", answered: true,
                         language: "ruby_rails")
    exercise = DailyExercise.create!(
      user: user, date: date, language: language, generated_at: date.to_time,
      problem_set: { section => { "question" => "q", "concept" => concept, "pitched_at" => rung } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date, submitted_at: date.to_time,
      answers: { section => answered ? "x" * 20 : "" }, concept_tags: { section => concept },
      section_ratings: { section => "right_level" }, ai_review: { section => { "rating" => ai, "correct" => "c" } }
    )
  end
end

RSpec.configure do |config|
  config.include MetConceptHelpers, type: :model
  config.include MetConceptHelpers, type: :request
end
