require "rails_helper"

RSpec.describe FakeService do
  let(:user) do
    User.create!(email: "fake-svc@example.com", name: "Fake", provider: "fake", api_keys: { "fake" => "fake-test-key" })
  end

  it "is a valid provider value on User" do
    expect(user).to be_valid
  end

  it "is what AiService.for returns for a fake-provider user" do
    expect(AiService.for(user)).to be_a(FakeService)
  end

  it "is refused by AiService.for outside a local environment" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    expect { AiService.for(user) }.to raise_error(SetupError, /test-only fake provider/)
  end

  describe "#generate_exercise" do
    it "answers with every ExerciseSection kind, and delivers sections with valid, non-'other' concepts" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")

      # Derived from the registry so "every kind" stays true when a kind is added.
      expect(described_class::EXERCISE_PROBLEM_SET.keys).to match_array(ExerciseSection.keys)
      expect(ExerciseSection.resolved_keys(problem_set, daily: DailyKinds::DEFAULT)).to include(*DailyKinds::DEFAULT.map(&:key))
      problem_set.each_value do |section|
        expect(section["concept"]).to be_present
        expect(section["concept"]).not_to eq("other")
      end
    end

    # A canned translation that added the guard would let the faithfulness specs pass while proving nothing.
    it "returns a translation that preserves the gap its own critique names" do
      expect(described_class::PSEUDOCODE_CRITIQUE["gaps"].join).to match(/empty/i)
      expect(described_class::PSEUDOCODE_TRANSLATION).not_to match(/empty\?|nil\?|blank\?|\.any\?/)
    end

    it "resolves to the architecture third when persisted, since architecture has top precedence" do
      user.update!(daily_section_count: ExerciseSection::MAX_SECTIONS)
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: problem_set,
                                        language: "ruby_rails", generated_at: Time.current)

      expect(ExerciseSection.resolved_key(exercise.problem_set, ExerciseSection.thirds)).to eq("architecture")
    end

    it "resolves its fourth shapes to plan_review, since plan_review has top precedence" do
      expect(ExerciseSection.resolved_key(described_class::EXERCISE_PROBLEM_SET, ExerciseSection.fourths)).to eq("plan_review")
    end

    it "delivers no more sections than a day holds" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      exercise = DailyExercise.new(problem_set: problem_set)

      expect(exercise.active_section_keys.size).to be <= ExerciseSection::MAX_SECTIONS
    end

    it "logs API usage with zero cost" do
      expect {
        described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      }.to change(ApiUsage, :count).by(1)

      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(0)
      expect(usage.tokens_out).to eq(0)
    end
  end

  describe "#generate_judged_exercise with a multi-file code review" do
    before do
      user.update!(skill_level: "mid_level")
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).and_return(:multi)
      set = described_class::EXERCISE_PROBLEM_SET.merge("code_review" => CodeReviewMultiFile::SECTION)
      stub_const("FakeService::REPLIES", described_class::REPLIES.merge("generate_exercise" => set.to_json))
    end

    it "delivers the files with their changed lines resolved to line numbers" do
      judged = described_class.new(user.api_key).generate_judged_exercise(user, language: "ruby_rails")
      section = judged.problem_set.fetch("code_review")

      expect(judged.dropped_sections).to be_empty
      expect(ExerciseSection::CodeReview.files(section).map(&:path)).to eq(%w[app/models/customer.rb app/jobs/loyalty_report_job.rb])
      expect(section["file_1_changed"]).to be_present.and(all(be_an(Integer)))
    end
  end

  describe "#review_sections" do
    it "returns ok: true for each requested section, independently gradable" do
      user_exercise = DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: described_class::EXERCISE_PROBLEM_SET
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: user_exercise, date: Date.current,
        answers: { "code_review" => "N+1 query", "pattern" => "Extract a service object", "architecture" => "Move it to a job" },
        submitted_at: Time.current
      )

      results = described_class.new(user.api_key).review_sections(user, user_exercise, response, sections: %w[code_review pattern architecture])

      expect(results.keys).to match_array(%w[code_review pattern architecture])
      results.each_value do |outcome|
        expect(outcome[:ok]).to be(true)
        expect(outcome[:review]["correct"]).to be_an(Array)
      end
    end

    # ReviewGrading swallows every difficulty-assessment error, so only this spec makes a broken scan loud.
    it "returns a difficulty for every section it was asked about" do
      user_exercise = DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: described_class::EXERCISE_PROBLEM_SET
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: user_exercise, date: Date.current,
        answers: { "code_review" => "N+1 query", "pattern" => "Extract a service object" },
        submitted_at: Time.current
      )
      sections = %w[code_review pattern architecture]

      results = described_class.new(user.api_key).review_sections(user, user_exercise, response, sections: sections)

      sections.each do |section|
        difficulty = results[section][:review]["difficulty"]
        expect(difficulty).to be_a(Hash), "#{section} came back with no difficulty note"
        expect(DailyResponse::DIFFICULTY_LEVELS).to include(difficulty["level"])
      end
    end

    it "raises a clear error when the section key can't be extracted from the prompt" do
      service = described_class.new(user.api_key)

      expect {
        service.send(:call, AiService.request_for("review_response", system: "s", prompt: "no section marker here"))
      }.to raise_error(/could not extract the section key/)
    end
  end

  describe "#call" do
    let(:service) { described_class.new(user.api_key) }
    # The purposes whose AiService caller hands the reply to parse_json_object; every other caller reads it as prose.
    let(:json_purposes) do
      %w[generate_exercise retry_section review_response assess_difficulty generate_concept_reference
         generate_recognition_guide pseudocode_critique judge_section judge_review]
    end
    let(:prompts_with_markers) do
      { "review_response"   => 'Grade ONLY the "code_review" section from the day\'s context above.',
        "assess_difficulty" => "## code_review\nThe section's context",
        "judge_section"     => "Section kind: code_review" }
    end

    def reply_for(purpose)
      service.send(:call, AiService.request_for(purpose, system: "s", prompt: prompts_with_markers.fetch(purpose, "p")))
    end

    it "holds one reply per purpose and no other" do
      expect(described_class::REPLIES.keys.sort).to eq(ApiUsage::PURPOSES.sort)
    end

    it "answers a walkthrough prompt for an unanswered section the same way" do
      prompt = %(Walk through the "code_review" section from the day's context above.)
      reply  = service.send(:call, AiService.request_for("review_response", system: "s", prompt: prompt))

      expect(JSON.parse(reply[:text])).to include("missed")
    end

    ApiUsage::PURPOSES.each do |purpose|
      it "answers #{purpose} with a zero-cost reply its caller can read" do
        result = reply_for(purpose)

        expect(result).to include(input_tokens: 0, output_tokens: 0, model: "fake", cache_read_tokens: 0, cache_write_tokens: 0)
        if json_purposes.include?(purpose)
          expect(JSON.parse(result[:text])).to be_a(Hash)
        else
          expect(result[:text]).to be_present
          expect { JSON.parse(result[:text]) }.to raise_error(JSON::ParserError)
        end
      end
    end

    it "raises a bare RuntimeError naming a purpose it has no reply for" do
      expect { service.send(:call, AiService::Request.build(purpose: "write_poem", system: "s", prompt: "p")) }
        .to raise_error { |error|
          expect(error.class).to eq(RuntimeError)
          expect(error.message).to eq('FakeService has no reply for purpose: "write_poem"')
        }
    end
  end

  describe FakeReplies do
    it "names the system-prompt marker of every purpose, each a phrase AiService's or a *Prompt class's prompts carry" do
      source = ([ "app/clients/ai_service.rb" ] + Dir[Rails.root.join("app/prompts/**/*.rb")]).map { |path| Rails.root.join(path).read }.join

      expect(FakeReplies::SYSTEM_PROMPT_MARKERS.keys.sort).to eq(ApiUsage::PURPOSES.sort)
      FakeReplies::SYSTEM_PROMPT_MARKERS.each_value { |marker| expect(source).to include(marker) }
    end

    it "finds the purpose whose marker a real system prompt carries" do
      expect(purpose_for(DuckPrompt::SYSTEM)).to eq("duck_thread")
      expect(purpose_for(ReviewProseJudgePrompt::SYSTEM)).to eq("judge_review")
      expect(purpose_for(FakeService.new(user.api_key).send(:build_system_prompt, "ruby_rails"))).to eq("generate_exercise")
    end

    it "raises naming a system prompt no marker matches" do
      expect { purpose_for("You are a poet") }.to raise_error(RuntimeError, /no marker matching the system prompt: "You are a poet"/)
    end
  end

  describe "#generate_concept_reference" do
    it "returns every required ConceptReference::REFERENCE_FIELDS field non-blank" do
      reference = described_class.new(user.api_key).generate_concept_reference(user, "n_plus_one", "ruby_rails")

      ConceptReference::REFERENCE_FIELDS.each do |field|
        expect(reference[field].to_s.strip).to be_present
      end
    end
  end

  describe "#explain_concept_differently" do
    it "returns non-blank plain prose, distinct from the review reframing" do
      reference = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                                           tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")

      text = described_class.new(user.api_key).explain_concept_differently(user, reference)

      expect(text).to be_present
      expect(text).not_to eq(described_class::EXPLAIN_DIFFERENTLY_TEXT)
    end
  end

  describe "#explain_differently" do
    it "returns non-blank plain prose" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                                        generated_at: Time.current, problem_set: described_class::EXERCISE_PROBLEM_SET)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                        answers: { "pattern" => "Extract a service object" })

      text = described_class.new(user.api_key).explain_differently(user, exercise, response, section: "pattern")

      expect(text).to be_present
    end
  end

  describe "#answer_follow_up" do
    it "returns non-blank plain prose" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                                        generated_at: Time.current, problem_set: described_class::EXERCISE_PROBLEM_SET)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                        answers: { "pattern" => "Extract a service object" })

      text = described_class.new(user.api_key).answer_follow_up(
        user, exercise, response, section: "pattern", question: "Why not just a bigger model?"
      )

      expect(text).to be_present
    end
  end
end
