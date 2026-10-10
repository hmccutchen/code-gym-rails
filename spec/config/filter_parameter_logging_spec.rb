require "rails_helper"

RSpec.describe "Request log parameter filtering" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  def outcome(params) = filter.filter(params)

  it "filters the login code" do
    expect(outcome("code" => "123456")).to eq("code" => "[FILTERED]")
  end

  # Entries match as substrings, so a bare :code would also hide these keys.
  it "matches the login code exactly, not every key that contains it" do
    expect(outcome("section" => "code_review", "code_review_mode" => "x"))
      .to eq("section" => "code_review", "code_review_mode" => "x")
  end

  it "filters what an engineer writes" do
    params = {
      "response" => { "answers" => { "code_review" => "my answer" } },
      "message" => "a duck message", "question" => "a follow-up",
      "pseudocode" => "a plan", "prior_alternates" => [ "an earlier framing" ],
      "thread" => [ { "role" => "user", "content" => "an earlier turn" } ]
    }

    expect(outcome(params).to_s).not_to include("my answer", "a duck message", "a follow-up", "a plan",
                                                "an earlier framing", "an earlier turn")
  end

  it "filters a person's name" do
    expect(outcome("user" => { "name" => "Ada" })).to eq("user" => { "name" => "[FILTERED]" })
  end

  it "matches a name exactly, not every key that contains it" do
    expect(outcome("filename" => "plan.rb")).to eq("filename" => "plan.rb")
  end

  it "filters an invite code" do
    expect(outcome("invite_code" => "ABCD")).to eq("invite_code" => "[FILTERED]")
  end

  it "filters a browser install's push keys but keeps its endpoint" do
    expect(outcome("p256dh" => "k", "auth" => "a", "endpoint" => "https://fcm.googleapis.com/x"))
      .to eq("p256dh" => "[FILTERED]", "auth" => "[FILTERED]", "endpoint" => "https://fcm.googleapis.com/x")
  end
end
