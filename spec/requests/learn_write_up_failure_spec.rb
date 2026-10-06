require "rails_helper"

# A concept reference row is shared, so a failed write-up is noted per user in
# the cache, where the status endpoint reads it and the page stops polling.
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
        "message" => "Your Gemini key has used today's free allowance, so the write-up didn't finish. The allowance resets at 3:00 am your time, Wednesday."
      )
      expect(status_body["message"]).not_to include("quota")
    end
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
