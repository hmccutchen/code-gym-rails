require "rails_helper"

# Checks the machine-checkable rules of AiService::PLAIN_LANGUAGE_STANDARD; the rest needs a reader.
RSpec.describe HandWrittenLearnText do
  standard = AiService::PLAIN_LANGUAGE_STANDARD

  # Read from the standard, so a phrase added there is checked here too.
  placeholder_phrases = standard.lines.find { |line| line.include?("Placeholder phrases") }
                                .scan(/"([^"]+)"/).flatten
                                .map { |phrase| phrase.sub(/[,.]\z/, "").downcase }

  def self.sentences(text)
    text.split(/(?<=[.?!])\s+/).map(&:strip).reject(&:empty?)
  end

  # The first word stands in for a sentence's construction, so only the plainest repetition is caught.
  def self.opening_word(sentence)
    sentence[/[[:alpha:]']+/]&.downcase
  end

  def self.placeholder_hits(text, phrases)
    normalized = text.downcase.tr("’", "'")
    phrases.select { |phrase| normalized.include?(phrase) }
  end

  def self.same_opening?(text)
    openings = sentences(text).map { |sentence| opening_word(sentence) }
    openings.size > 1 && openings.uniq.size == 1
  end

  it "reads the placeholder phrases from the standard" do
    expect(placeholder_phrases).to eq([ "please note", "at this time", "it's worth mentioning" ])
  end

  it "lists every module that answers .learn_text" do
    defining = Rails.root.glob("app/**/*.rb").select { |path| path.read.include?("def self.learn_text") }
                    .map { |path| path.read[/^(?:module|class) (\w+)/, 1] } - [ described_class.name ]

    expect(described_class::MODULES.map(&:name)).to match_array(defining)
  end

  describe "the checks themselves" do
    it "catch a placeholder phrase" do
      expect(self.class.placeholder_hits("Please note, the cache expires.", placeholder_phrases)).to eq([ "please note" ])
    end

    it "catch every sentence opening the same way" do
      expect(self.class.same_opening?("You open the file. You read the name.")).to be(true)
      expect(self.class.same_opening?("You open the file. The name says enough.")).to be(false)
    end

    it "leave a single sentence alone" do
      expect(self.class.same_opening?("You open the file.")).to be(false)
    end
  end

  described_class.learn_text.each do |id, text|
    describe id do
      it "uses none of the standard's placeholder phrases" do
        expect(self.class.placeholder_hits(text, placeholder_phrases)).to be_empty
      end

      it "does not start every sentence the same way" do
        expect(self.class.same_opening?(text)).to be(false)
      end
    end
  end
end
