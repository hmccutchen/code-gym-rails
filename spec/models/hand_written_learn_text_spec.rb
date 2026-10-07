require "rails_helper"

# Holds hand-written Learn text to the rules in AiService::PLAIN_LANGUAGE_STANDARD
# that code can check (PlainLanguageChecks). The rest of the standard needs a
# reader's judgment.
RSpec.describe HandWrittenLearnText do
  it "lists every module that answers .learn_text" do
    defining = Rails.root.glob("app/**/*.rb").select { |path| path.read.include?("def self.learn_text") }
                    .map { |path| path.read[/^(?:module|class) (\w+)/, 1] } - [ described_class.name ]

    expect(described_class::MODULES.map(&:name)).to match_array(defining)
  end

  described_class.learn_text.each do |id, text|
    describe id do
      it "uses none of the standard's placeholder phrases" do
        expect(PlainLanguageChecks.placeholder_hits(text)).to be_empty
      end

      it "does not start every sentence the same way" do
        expect(PlainLanguageChecks.same_opening?(text)).to be(false)
      end
    end
  end
end
