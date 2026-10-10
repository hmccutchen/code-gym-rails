require "rails_helper"

# The request itself is unchanged on a trial; trial_isolation_spec holds that.
RSpec.describe "AiService on a trial", type: :model do
  let(:user) { create_trial_user(provider: "fake", cap: 2) }

  it "builds the provider on the house key and marks every usage row" do
    service = AiService.for(user)

    expect(service).to be_a(FakeService)
    expect(service.instance_variable_get(:@api_key)).to eq("fake-house-key")
    expect(service).to be_house_key

    service.duck_response(user, DailyExercise.new(problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }),
                          section: "code_review", message: "hi")
    expect(ApiUsage.last).to have_attributes(house_key: true, provider: "fake", purpose: "duck_thread")
  end

  it "refuses before the call once the account's cap is reached, writing no row" do
    service = AiService.for(user)
    2.times do
      ApiUsage.create!(user: user, purpose: "duck_thread", provider: "fake", house_key: true,
                       tokens_in: 1, tokens_out: 1, date: Date.current)
    end
    expect(service).not_to receive(:call)

    expect {
      service.send(:call_and_log, user, purpose: "duck_thread", system: "s", prompt: "p")
    }.to raise_error(AiService::TrialAllowanceError)
    expect(ApiUsage.count).to eq(2)
  end

  it "raises TrialEndedError from .for once the trial has ended" do
    travel_to(user.trial_ends_at + 1.hour) do
      expect { AiService.for(user) }.to raise_error(AiService::TrialEndedError)
    end
  end

  it "carries the credential kind into the services the review builds per section" do
    service = AiService.for(user)

    expect(service.send(:fresh_service)).to be_house_key
    expect(AiService.for(create_user_with_key).send(:fresh_service)).not_to be_house_key
  end

  it "never runs the gate for an own-key account" do
    service = AiService.for(create_user_with_key)
    allow(service).to receive(:call).and_return(text: "ok", input_tokens: 1, output_tokens: 1, truncated: false)
    expect(TrialAllowance).not_to receive(:check!)

    service.send(:call_and_log, create_user_with_key(email: "b@example.com"), purpose: "duck_thread", system: "s", prompt: "p")
    expect(ApiUsage.last).to have_attributes(house_key: false)
  end
end
