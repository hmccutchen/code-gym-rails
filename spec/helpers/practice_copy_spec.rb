require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  let(:user) { create_user_with_key }

  before do
    owner = user
    helper.define_singleton_method(:current_user) { owner }
  end

  it "retains inactive copy verbatim with initiation off" do
    expect(helper.practice_copy("exercise_mix.intro")).to eq(I18n.t("exercise_mix.intro"))
    expect(helper.practice_copy("learn.drill.offer")).to eq(I18n.t("learn.drill.offer"))
  end

  it "shows explicit unavailable copy and safely logs a persisted invalid historical receipt" do
    exercise = user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current, problem_set: {})
    response = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
      mastery_application: { "version" => 99, "secret" => "RAW-GAP-ANSWER" })
    expect(Rails.logger).to receive(:warn).with("[practice_display] user_id=#{user.id} error=ArgumentError").once
    expect(helper.practice_copy("exercise_mix.intro")).to eq(I18n.t("protected_practice.unavailable"))
    expect(helper.practice_copy("learn.drill.offer")).to eq(I18n.t("protected_practice.unavailable"))
    expect(response.reload.mastery_application).to include("secret" => "RAW-GAP-ANSWER")
    expect { PracticePolicyMode.active?(user) }.to raise_error(ArgumentError)
  end

  it "describes enrolled opportunities without promising an extra section, next slot or automatic target change" do
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", practice_requests: {
      "pattern" => { "mode" => "normal_retry", "source_response_id" => 1, "requested_at" => Time.current.utc.iso8601(6) }
    })
    expect(helper.practice_copy("exercise_mix.intro")).to include("two-section", "pause")
    expect(helper.practice_copy("learn.drill.offer")).to include("does not add a section or promise")
  end
end
