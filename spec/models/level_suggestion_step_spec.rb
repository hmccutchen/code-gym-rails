require "rails_helper"

RSpec.describe LevelSuggestionStep do
  def parse(*entries) = described_class.parse_all(entries)

  it "reads one-rung moves up and down the ladder" do
    steps = parse({ "kind" => "code_review", "from" => "junior", "to" => "mid_level" },
                  { "kind" => "pattern", "from" => "senior", "to" => "mid_level" })

    expect(steps).to eq([ described_class.new(kind: "code_review", from: "junior", to: "mid_level"),
                          described_class.new(kind: "pattern", from: "senior", to: "mid_level") ])
  end

  it "reads request parameters" do
    params = ActionController::Parameters.new(steps: [ { kind: "code_review", from: "junior", to: "mid_level" } ])

    expect(described_class.parse_all(params[:steps]).sole.to).to eq("mid_level")
  end

  [
    [ "a move of two rungs", { "kind" => "code_review", "from" => "junior", "to" => "senior" } ],
    [ "a move to principal engineer", { "kind" => "code_review", "from" => "senior", "to" => "principal_engineer" } ],
    [ "no move", { "kind" => "code_review", "from" => "junior", "to" => "junior" } ],
    [ "an unknown kind", { "kind" => "crossword", "from" => "junior", "to" => "mid_level" } ],
    [ "a missing field", { "kind" => "code_review", "to" => "mid_level" } ],
    [ "a non-string level", { "kind" => "code_review", "from" => 1, "to" => "mid_level" } ]
  ].each do |label, entry|
    it "refuses #{label}" do
      expect(parse(entry)).to be_nil
    end
  end

  it "refuses an empty list, a non-list and a kind listed twice" do
    step = { "kind" => "code_review", "from" => "junior", "to" => "mid_level" }

    expect(described_class.parse_all([])).to be_nil
    expect(described_class.parse_all(step)).to be_nil
    expect(described_class.parse_all("steps")).to be_nil
    expect(parse(step, step)).to be_nil
  end
end
