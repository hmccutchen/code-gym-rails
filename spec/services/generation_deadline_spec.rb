require "rails_helper"

RSpec.describe GenerationDeadline do
  let(:start) { Time.utc(2026, 10, 14, 15, 0, 0) }
  let(:now)   { [ start ] }
  let(:clock) { -> { now.first } }

  def deadline_in(seconds) = described_class.new(start + seconds, clock: clock)

  def request(purpose, blocking: false) = AiService.request_for(purpose, system: "s", prompt: "p", blocking: blocking)

  def worst(purpose) = AiService.worst_case_seconds_for(purpose)

  describe "#ensure_fits!" do
    it "lets a call start when its own worst case still ends by the deadline" do
      expect { deadline_in(worst("judge_section")).ensure_fits!(request("judge_section")) }.not_to raise_error
    end

    it "refuses a call whose worst case would run past the deadline, even with time left" do
      expect { deadline_in(worst("judge_section") - 1).ensure_fits!(request("judge_section")) }
        .to raise_error(ProviderError::DeadlineError)
    end

    it "reserves what the request itself can take, so a blocking draft needs its shorter read, not the full one" do
      blocking = request("generate_exercise", blocking: true)

      expect(blocking.worst_case_seconds).to be < worst("generate_exercise")
      expect { deadline_in(blocking.worst_case_seconds).ensure_fits!(blocking) }.not_to raise_error
    end

    it "is a timeout to everything that classifies provider failures" do
      expect(ProviderError::DeadlineError.new("judge_section")).to be_a(ProviderError::TimeoutError)
      expect(ProviderFailure.classify(ProviderError::DeadlineError.new("judge_section"))).to eq("timeout")
    end

    it "never refuses anything when it has no end" do
      expect { described_class::NONE.ensure_fits!(request("generate_exercise")) }.not_to raise_error
    end
  end

  describe "#leaving" do
    it "ends earlier by what it keeps back, so a call is admitted only if the reserved time still fits after it" do
      deadline = deadline_in(worst("retry_section") + worst("judge_section"))

      expect { deadline.leaving(worst("judge_section")).ensure_fits!(request("retry_section")) }.not_to raise_error
      expect { deadline.leaving(worst("judge_section") + 1).ensure_fits!(request("retry_section")) }
        .to raise_error(ProviderError::DeadlineError)
    end

    it "keeps no end when there was none" do
      expect(described_class::NONE.leaving(60)).to be(described_class::NONE)
    end
  end

  it "reads the clock at each check, so a later check sees the time spent since an earlier one" do
    deadline = deadline_in(worst("judge_section"))
    deadline.ensure_fits!(request("judge_section"))
    now[0] = start + 1

    expect { deadline.ensure_fits!(request("judge_section")) }.to raise_error(ProviderError::DeadlineError)
  end
end
