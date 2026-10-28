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
      allow(CodeFormat).to receive(:all).and_call_original
      formatted = CodeFormat.all(RealSource.all.map(&:text), language: RealSource::LANGUAGE)

      formatted.each { |snippet| expect { described_class.reject_unusable!("snippet" => snippet) }.not_to raise_error }
    end
  end
end
