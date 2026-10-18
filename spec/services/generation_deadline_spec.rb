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

  describe "#guard" do
    let(:calls) { [] }
    let(:provider) do
      JudgedGeneration::Provider.new(
        judge_section: ->(*args, **options) { calls << [ :judge, args, options ]; :verdict },
        retry_section: ->(*args) { calls << [ :retry, args ]; :section }
      )
    end

    it "passes calls through while each one still fits" do
      guarded = deadline_in(worst("retry_section")).guard(provider)

      expect(guarded.judge_section.call(:user, :kind, :section, rung: "junior", locked: false)).to eq(:verdict)
      expect(guarded.retry_section.call(:user, :language, :draft, :kind, :concept)).to eq(:section)
      expect(calls.map(&:first)).to eq(%i[judge retry])
    end

    it "stops a retry that no longer fits while a judge still does, so only late work is lost" do
      guarded = deadline_in(worst("judge_section")).guard(provider)

      expect { guarded.retry_section.call(:user, :language, :draft, :kind, :concept) }.to raise_error(AiService::DeadlineError)
      expect(guarded.judge_section.call(:user, :kind, :section, rung: "junior", locked: false)).to eq(:verdict)
      expect(calls.map(&:first)).to eq(%i[judge])
    end

    it "checks the clock at each call, not once when guarded" do
      guarded = deadline_in(worst("judge_section")).guard(provider)
      now[0] = start + 1

      expect { guarded.judge_section.call(:user, :kind, :section, rung: "junior", locked: false) }
        .to raise_error(AiService::DeadlineError)
      expect(calls).to be_empty
    end

    it "returns the provider unchanged when there is no end" do
      expect(described_class::NONE.guard(provider)).to be(provider)
    end
  end
end
