require "rails_helper"

# The test store is :null_store; these examples swap in a real one.
RSpec.describe "Learn write-up failures", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) do
    create_user_with_key(time_zone: "America/New_York").tap do |u|
      u.update!(provider: "gemini", api_keys: { "gemini" => "AIzaTestKey" }, language: "ruby_rails")
    end
  end

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    login_as(user)
  end

  def status_body
    get learn_concept_status_path(bucket: "ruby_rails", concept: "n_plus_one", awaiting: "guide")
    response.parsed_body
  end

  def run_job_against(status, body)
    conn = Faraday.new { |f| f.adapter(:test) { |stub| stub.post(GeminiService::API_URL) { [ status, {}, body ] } } }
    allow_any_instance_of(GeminiService).to receive(:build_connection).and_return(conn)
    allow(Rails.logger).to receive(:warn)
    GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)
  end

  it "reports why the write-up stopped, with the reset in the user's zone, and no provider text" do
    travel_to(Time.utc(2026, 10, 6, 14)) do
      run_job_against(429, Rails.root.join("spec/fixtures/provider_errors/gemini_429_daily.json").read)

      expect(ConceptReference.count).to eq(0)
      expect(status_body).to eq(
        "ready" => false, "failed" => "daily_limit",
        "message" => "Your Gemini key has reached its daily limit, so the write-up didn't finish. The limit resets at 3:00 am your time, Wednesday."
      )
      expect(status_body["message"]).not_to include("quota")
    end
  end

  it "names the provider the job used, not the one the user has since switched to" do
    travel_to(Time.utc(2026, 10, 6, 14)) do
      run_job_against(429, Rails.root.join("spec/fixtures/provider_errors/gemini_429_daily.json").read)
      user.update!(provider: "anthropic", api_keys: user.api_keys.merge("anthropic" => "sk-ant-test"))

      expect(status_body["message"]).to start_with("Your Gemini key has reached its daily limit")
    end
  end

  # An unusable reply raises after the call, so the error carries no provider stamp of its own.
  it "names the job's provider for a reply it could not use, after a switch" do
    unusable = { "status" => "completed", "outputs" => [ { "type" => "text", "text" => "not json" } ],
                 "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "not json" } ] } ],
                 "usage" => { "total_input_tokens" => 10, "total_output_tokens" => 5 } }.to_json
    run_job_against(200, unusable)
    user.update!(provider: "anthropic", api_keys: user.api_keys.merge("anthropic" => "sk-ant-test"))

    expect(status_body["failed"]).to eq("other")
    expect(status_body["message"]).to start_with("Gemini sent back something Code Gym couldn't use")
  end

  it "forgets the note after its expiry, so the page can ask again" do
    travel_to(Time.utc(2026, 10, 6, 14)) do
      run_job_against(503, "<html>down</html>")
      expect(status_body["failed"]).to eq("outage")

      travel(ConceptReferenceFailures::EXPIRY + 1.minute)
      expect(status_body).to eq("ready" => false)
    end
  end

  it "clears the note when the write-up is asked for again, and when it lands" do
    run_job_against(503, "<html>down</html>")
    expect(status_body["failed"]).to eq("outage")

    post prepare_learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
    expect(status_body).to eq("ready" => false)

    run_job_against(503, "<html>down</html>")
    expect(status_body["failed"]).to eq("outage")
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "t", explanation: "e", code_example: "c",
                             senior_lens: "s", guide_plain_language: "g", guide_worked_example: "w", guide_pitfalls: "p")
    expect(status_body).to eq("ready" => true)
  end

  it "keeps one user's note away from another" do
    run_job_against(503, "<html>down</html>")
    other = create_user_with_key(email: "other@example.com").tap { |u| u.update!(language: "ruby_rails") }
    login_as(other)

    expect(status_body).to eq("ready" => false)
  end
end
