require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261002170100_add_review_provider_to_daily_responses.rb")
require migration_path.to_s

RSpec.describe AddReviewProviderToDailyResponses do
  let(:user) { User.create!(email: "reviewed@example.com", name: "Reviewed", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }) }

  def response_for(date, ai_review:)
    exercise = user.daily_exercises.create!(date: date, problem_set: { "code_review" => {} }, generated_at: Time.current)
    user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current, ai_review: ai_review)
  end

  it "records the user's provider on reviewed responses only" do
    reviewed = response_for(Date.new(2026, 9, 28), ai_review: { "code_review" => { "rating" => "solid" } })
    unreviewed = response_for(Date.new(2026, 9, 29), ai_review: {})

    ActiveRecord::Migration.suppress_messages do
      described_class.new.migrate(:down)
      described_class.new.migrate(:up)
    end
    DailyResponse.reset_column_information

    expect(reviewed.reload.review_provider).to eq("anthropic")
    expect(unreviewed.reload.review_provider).to be_nil
  end
end
