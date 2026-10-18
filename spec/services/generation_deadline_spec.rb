require "rails_helper"

RSpec.describe GenerationDeadline do
  let(:start) { Time.utc(2026, 10, 14, 15, 0, 0) }
  let(:now)   { [ start ] }
  let(:clock) { -> { now.first } }

  def deadline_in(seconds) = described_class.new(start + seconds, clock: clock)

  def worst(purpose) = AiService.worst_case_seconds_for(purpose)

  describe "#ensure_fits!" do
    it "lets a call start when its own worst case still ends by the deadline" do
      expect { deadline_in(worst("judge_section")).ensure_fits!("judge_section") }.not_to raise_error
    end

    it "refuses a call whose worst case would run past the deadline, even with time left" do
      expect { deadline_in(worst("judge_section") - 1).ensure_fits!("judge_section") }
        .to raise_error(AiService::DeadlineError)
    end

    it "is a timeout to everything that classifies provider failures" do
      expect(AiService::DeadlineError.new("judge_section")).to be_a(AiService::TimeoutError)
      expect(ProviderFailure.classify(AiService::DeadlineError.new("judge_section"))).to eq("timeout")
    end

    it "never refuses anything when it has no end" do
      expect { described_class::NONE.ensure_fits!("generate_exercise") }.not_to raise_error
    end
  end

  it "reads the clock at each check, so a later check sees the time spent since an earlier one" do
    deadline = deadline_in(worst("judge_section"))
    deadline.ensure_fits!("judge_section")
    now[0] = start + 1

    expect { deadline.ensure_fits!("judge_section") }.to raise_error(AiService::DeadlineError)
  end
end
