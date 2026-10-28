require "rails_helper"

RSpec.describe ExerciseSection::CodeReview do
  describe ".reject_unusable!" do
    def snippet_of(count) = Array.new(count) { |index| "line_#{index} = #{index}" }.join("\n")

    it "accepts a snippet at the line cap" do
      expect { described_class.reject_unusable!("snippet" => snippet_of(described_class::MAX_SNIPPET_LINES)) }.not_to raise_error
    end

    it "refuses a snippet past the line cap, naming its length and none of its code" do
      expect { described_class.reject_unusable!("snippet" => snippet_of(described_class::MAX_SNIPPET_LINES + 1)) }
        .to raise_error(ProviderError::InvalidResponseError) { |error|
          expect(error.message).to include("#{described_class::MAX_SNIPPET_LINES + 1} lines")
          expect(error.message).not_to include("line_0")
        }
    end

    it "counts the lines shown, not the blank ones between them" do
      spaced = Array.new(described_class::MAX_SNIPPET_LINES, "x = 1").join("\n\n")

      expect { described_class.reject_unusable!("snippet" => spaced) }.not_to raise_error
    end

    it "refuses a missing, blank or non-string snippet" do
      [ nil, "  \n ", 42 ].each do |value|
        expect { described_class.reject_unusable!("snippet" => value) }
          .to raise_error(ProviderError::InvalidResponseError, /snippet/), "accepted #{value.inspect}"
      end
    end

    it "accepts every curated real-source excerpt as formatted, since a grounded snippet keeps its excerpt's shape" do
      formatted = CodeFormat.all(RealSource.all.map(&:text), language: RealSource::LANGUAGE)

      formatted.each { |snippet| expect { described_class.reject_unusable!("snippet" => snippet) }.not_to raise_error }
    end
  end
end

RSpec.describe ProblemSetIngest, "code review snippet length" do
  it "counts the snippet after formatting, so code the formatter shortens is kept" do
    long_before_formatting = Array.new(ExerciseSection::CodeReview::MAX_SNIPPET_LINES + 1, "x = 1").join("\n")
    allow(CodeFormat).to receive(:all) { |snippets, **| snippets.map { |code| code.lines.first(5).join } }
    set = { "code_review" => FakeService::EXERCISE_PROBLEM_SET.fetch("code_review").deep_dup.merge("snippet" => long_before_formatting) }

    result = described_class.call(set, language: "ruby_rails", daily: DailyKinds::DEFAULT, expected_keys: set.keys)

    expect(result.unusable_sections).to be_empty
    expect(result.problem_set["code_review"]["snippet"].lines.size).to eq(5)
  end
end
