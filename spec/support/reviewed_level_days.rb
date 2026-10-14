module ReviewedLevelDays
  def reviewed_level_day(user, date, sections)
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current,
      problem_set: sections.transform_values { |section| { "question" => "q", "snippet" => "s", "pitched_at" => section[:rung] } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: sections.transform_values { "a" * 20 },
      section_ratings: sections.transform_values { |section| section.fetch(:self, "right_level") },
      ai_review: sections.transform_values do |section|
        { "rating" => section.fetch(:ai, "solid"), "correct" => "c", "rubric" => AiService::RUBRIC_VERSION }
      end
    )
  end

  def reviewed_level_days(user, kind, rung, count, ending: Date.current, **ratings)
    count.times { |ago| reviewed_level_day(user, ending - ago, { kind => { rung: rung, **ratings } }) }
  end
end

RSpec.configure do |config|
  config.include ReviewedLevelDays, type: :model
  config.include ReviewedLevelDays, type: :request
end
