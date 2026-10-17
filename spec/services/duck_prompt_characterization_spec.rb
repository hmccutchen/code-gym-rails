require "rails_helper"

# Rebaseline with UPDATE_PROMPT_SNAPSHOTS=1 only when a duck prompt change is the intended deliverable.
RSpec.describe "duck prompt characterization" do
  let(:user) { User.create!(email: "duck-snapshot@example.com", name: "Duck Snapshot") }

  let(:exercise) do
    DailyExercise.new(language: "ruby_rails", problem_set: {
      "code_review" => {
        "title"    => "Invoice totals",
        "scenario" => "A nightly job emails each customer their open invoices.",
        "question" => "What would you change before this ships?",
        "snippet"  => "Customer.all.each do |customer|\n  customer.invoices.open.sum(:total)\nend"
      }
    })
  end

  let(:recording_class) do
    Class.new(AiService) do
      attr_reader :requests

      def initialize(*)
        @api_key  = "unused"
        @requests = []
      end

      private

      def call(request)
        @requests << request
        { text: "What happens to the query count as customers grow?", input_tokens: 1, output_tokens: 1, truncated: false }
      end

      def build_connection = nil
    end
  end

  def recorded_request(message:, thread:)
    service = recording_class.new
    service.duck_response(user, exercise, section: "code_review", message: message, thread: thread)
    service.requests.sole
  end

  def rendered(request)
    <<~SNAPSHOT
      === system ===
      #{request.system}
      === history ===
      #{JSON.pretty_generate(request.history)}
      === prompt ===
      #{request.prompt}
      === settings ===
      #{JSON.pretty_generate(request.to_h.except(:system, :prompt, :history))}
    SNAPSHOT
  end

  def snapshot_path(name) = Rails.root.join("spec/fixtures/duck_prompt_snapshots/#{name}.txt")

  {
    "first_turn"   => { message: "What is this even asking?", thread: [] },
    "with_history" => {
      message: "Is it the loop?",
      thread:  [ { role: "user", content: "I don't see anything wrong." },
                 { role: "assistant", content: "What does each pass through the loop ask the database for?" } ]
    }
  }.each do |name, turn|
    it "sends the #{name.tr("_", " ")} request byte for byte as recorded" do
      text = rendered(recorded_request(**turn))
      path = snapshot_path(name)
      File.write(path, text) if ENV["UPDATE_PROMPT_SNAPSHOTS"]

      expect(path).to exist,
        "No snapshot at #{path.relative_path_from(Rails.root)}. " \
        "Record it against unmodified code with UPDATE_PROMPT_SNAPSHOTS=1."
      expect(text).to eq(File.read(path))
    end
  end

  it "sends the same bytes when stored turns come back with string keys" do
    stored = [ { "role" => "user", "content" => "I don't see anything wrong." },
               { "role" => "assistant", "content" => "What does each pass through the loop ask the database for?" } ]

    expect(rendered(recorded_request(message: "Is it the loop?", thread: stored))).to eq(File.read(snapshot_path("with_history")))
  end

  it "keeps the duck's instructions as the system prompt's opening bytes" do
    expect(recorded_request(message: "hm", thread: []).system).to start_with(AiService::DUCK_SYSTEM_PROMPT)
  end
end
