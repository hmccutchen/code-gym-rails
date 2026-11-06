module MasteryWriteHelpers
  def partially_review_concept!(user, concept:, date: Date.current)
    keys = %w[code_review pattern]
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: keys.index_with { { "concept" => concept } })
    response = user.daily_responses.create!(date: date, daily_exercise: exercise, submitted_at: Time.current,
      answers: keys.index_with { "An answer" }, concept_tags: keys.index_with { concept },
      section_ratings: keys.index_with { "right_level" }, ai_review: { "pattern" => { "rating" => "strong" } })
    apply_mastery_review!(response, sections: %w[pattern], apply_session_countdown: true, previous_review_keys: [], initiate: true)
    response
  end

  def apply_mastery_review!(response, sections:, apply_session_countdown:, previous_review_keys: nil, **options)
    previous_review_keys ||= (response.ai_review || {}).keys - sections
    pending = response.changes.transform_values(&:last)
    ApplicationRecord.transaction do
      User.lock.find(response.user_id)
      locked = DailyResponse.lock.find(response.id)
      locked.assign_attributes(pending)
      ConceptMastery.record_review!(locked, sections: sections, apply_session_countdown: apply_session_countdown,
        previous_review_keys: previous_review_keys, **options)
      locked.save!
    end
    response.reload
  end
end

RSpec.configure { |config| config.include MasteryWriteHelpers }
