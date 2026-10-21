require "rails_helper"

RSpec.describe ReviewFollowUp do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
  let(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q" } })
  end
  let(:daily_response) do
    user.daily_responses.create!(daily_exercise: exercise, date: Date.current, answers: {})
  end

  it "requires a section and content" do
    record = ReviewFollowUp.new(daily_response: daily_response, role: :user)
    expect(record).not_to be_valid
    expect(record.errors.attribute_names).to include(:section, :content)
  end

  it "exposes role predicates with a prefix" do
    record = ReviewFollowUp.create!(daily_response: daily_response, section: "code_review",
                                    role: :assistant, content: "Because the query runs per row.")
    expect(record.role_assistant?).to be(true)
    expect(record.role_user?).to be(false)
  end

  it "is destroyed with its response" do
    ReviewFollowUp.create!(daily_response: daily_response, section: "code_review", role: :user, content: "Why?")
    expect { daily_response.destroy }.to change(ReviewFollowUp, :count).by(-1)
  end
end
