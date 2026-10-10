require "rails_helper"

RSpec.describe RubricCheck do
  def review(rating:, missed: [ "a", "b" ], gaps: [])
    { "rating" => rating, "missed" => missed, "essential_gaps" => gaps }
  end

  it "agrees when a solid or strong rating lists no essential gap" do
    %w[solid strong].each do |rating|
      expect(described_class.new(review(rating: rating, gaps: [])).agrees?).to be(true), rating
    end
  end

  it "disagrees when a solid or strong rating lists an essential gap" do
    %w[solid strong].each do |rating|
      expect(described_class.new(review(rating: rating, gaps: [ 1 ])).agrees?).to be(false), rating
    end
  end

  it "agrees when a beginner or developing rating lists an essential gap" do
    %w[beginner developing].each do |rating|
      expect(described_class.new(review(rating: rating, gaps: [ 0 ])).agrees?).to be(true), rating
    end
  end

  it "disagrees when a beginner or developing rating lists no essential gap" do
    %w[beginner developing].each do |rating|
      expect(described_class.new(review(rating: rating, gaps: [])).agrees?).to be(false), rating
    end
  end

  it "reads the gaps as sorted, distinct positions in missed" do
    expect(described_class.new(review(rating: "developing", gaps: [ 1, 0, 1 ])).essential_gaps).to eq([ 0, 1 ])
  end

  [
    [ "a missing key",                     nil ],
    [ "a non-array",                       "0" ],
    [ "a position past the end of missed", [ 2 ] ],
    [ "a negative position",               [ -1 ] ],
    [ "a non-integer position",            [ "0" ] ],
    [ "a float position",                  [ 0.0 ] ]
  ].each do |label, gaps|
    it "cannot be checked when essential_gaps is #{label}" do
      check = described_class.new(review(rating: "solid", gaps: gaps))

      expect(check.essential_gaps).to be_nil
      expect(check.agrees?).to be_nil
    end
  end

  it "cannot be checked when the rating is outside the vocabulary" do
    expect(described_class.new(review(rating: "great", gaps: [])).agrees?).to be_nil
  end

  # The grader numbers the list as returned, so skipping a blank would shift every later position.
  it "numbers missed entries as returned, blanks included" do
    check = described_class.new(review(rating: "developing", missed: [ "a", "", "b" ], gaps: [ 2 ]))

    expect(check.essential_gaps).to eq([ 2 ])
    expect(check.missed_count).to eq(3)
  end

  it "counts an older review's single missed string as one entry" do
    check = described_class.new(review(rating: "developing", missed: "One string from an older review.", gaps: [ 0 ]))

    expect(check.essential_gaps).to eq([ 0 ])
  end
end
