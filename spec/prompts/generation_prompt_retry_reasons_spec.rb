require "rails_helper"

RSpec.describe GenerationPrompt::RetryReasons do
  let(:snapshot_dir) { Rails.root.join("spec/fixtures/retry_reason_snapshots") }
  let(:user) { User.new(email: "retry@example.com", name: "Retry", skill_level: "senior") }

  def retry_line(cause)
    prompt = render_generation_prompt(user, "ruby_rails", only: ExerciseSection::Pattern, fixed_concept: "service_objects",
                                      pattern: :pattern, retry_cause: cause)
    prompt[/^- This section replaces .*$/]
  end

  it "has one line for each judge principle and each kind's refusal, and nothing else" do
    refusals = ExerciseSection.all.flat_map { |kind| kind.refusal_codes.map { |code| "#{kind.key}.#{code}" } }

    expect(described_class::LINES.keys).to contain_exactly(*JudgeVerdict::PRINCIPLES, *refusals)
  end

  it "gives no reason when none was recorded, only a new section for the same concept" do
    [ nil, "not_a_recorded_cause" ].each do |cause|
      line = retry_line(cause)

      expect(line).to include("`service_objects`", "Write a new section for the same concept.")
      expect(line).not_to include("because", "wording alone")
    end
  end

  described_class::LINES.each_key do |cause|
    it "states the #{cause} reason as its recorded line" do
      line = retry_line(cause)
      path = snapshot_dir.join("#{cause}.txt")
      File.write(path, "#{line}\n") if ENV["UPDATE_PROMPT_SNAPSHOTS"]

      expect(line).to include(described_class::LINES.fetch(cause))
      expect(path).to exist
      expect("#{line}\n").to eq(File.read(path))
    end
  end

  it "keeps no snapshot for a cause the table no longer has" do
    expect(Dir.children(snapshot_dir).sort).to eq(described_class::LINES.keys.map { |cause| "#{cause}.txt" }.sort)
  end
end
