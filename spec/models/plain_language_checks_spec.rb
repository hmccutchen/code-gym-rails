require "rails_helper"

RSpec.describe PlainLanguageChecks do
  it "reads the placeholder phrases from the standard" do
    expect(described_class::PLACEHOLDER_PHRASES).to eq([ "please note", "at this time", "it's worth mentioning" ])
  end

  it "catches a placeholder phrase, curly apostrophes included" do
    expect(described_class.placeholder_hits("Please note, the cache expires.")).to eq([ "please note" ])
    expect(described_class.placeholder_hits("It’s worth mentioning the cache.")).to eq([ "it's worth mentioning" ])
  end

  it "catches every sentence opening the same way, and leaves a single sentence alone" do
    expect(described_class.same_opening?("You open the file. You read the name.")).to be(true)
    expect(described_class.same_opening?("You open the file. The name says enough.")).to be(false)
    expect(described_class.same_opening?("You open the file.")).to be(false)
  end

  it "flags a not-X-but-Y sentence and leaves a plain negative alone" do
    text = "Idempotent does not mean it runs once, but that the effect does not pile up. It does not retry."

    expect(described_class.contrast_hits(text)).to eq([ "Idempotent does not mean it runs once, but that the effect does not pile up." ])
  end

  it "flags a sentence past the word limit" do
    long = "#{([ 'word' ] * (described_class::LONG_SENTENCE_WORDS + 1)).join(' ')}."

    expect(described_class.long_sentences("Short one. #{long}")).to eq([ long ])
  end

  it "counts words, exclamation points and pleases" do
    report = described_class.report("Please retry! Don't panic! It's fine.")

    expect(report).to include(words: 6, exclamation_points: 2, pleases: 1, placeholder_phrases: [], same_opening: false)
  end
end
