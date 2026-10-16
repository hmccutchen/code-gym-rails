require "rails_helper"

RSpec.describe TrackChange do
  def change(levels, locked: [], from: "junior", to: "mid_level")
    described_class.new(levels: levels, locked: locked, from: from, to: to)
  end

  it "clears unlocked targets at the old level and at the new level" do
    result = change({ "code_review" => "junior", "pattern" => "mid_level" })

    expect(result.levels).to eq({})
    expect(result.cleared).to contain_exactly("code_review", "pattern")
  end

  it "keeps a target above the new level and one below the old level" do
    result = change({ "pattern" => "senior", "challenge" => "junior" }, from: "mid_level", to: "senior")

    expect(result.levels).to eq("challenge" => "junior")
    expect(result.cleared).to eq([ "pattern" ])

    upward = change({ "pattern" => "senior", "challenge" => "junior" }, from: "junior", to: "mid_level")
    expect(upward.levels).to eq("pattern" => "senior")
  end

  it "keeps a locked target at the old level" do
    result = change({ "code_review" => "junior", "pattern" => "junior" }, locked: [ "code_review" ])

    expect(result.levels).to eq("code_review" => "junior")
    expect(result.cleared).to eq([ "pattern" ])
  end

  it "keeps a target between the two levels on a two-rung move" do
    result = change({ "code_review" => "junior", "pattern" => "mid_level", "challenge" => "senior" },
                    from: "junior", to: "senior")

    expect(result.levels).to eq("pattern" => "mid_level")
  end

  it "works the same way on a move down" do
    result = change({ "code_review" => "senior", "pattern" => "mid_level", "challenge" => "junior" },
                    from: "senior", to: "mid_level")

    expect(result.levels).to eq("challenge" => "junior")
  end

  it "leaves principal engineer targets alone unless the move reaches principal" do
    expect(change({ "architecture" => "principal_engineer" }).levels).to eq("architecture" => "principal_engineer")
    expect(change({ "architecture" => "principal_engineer" }, from: "senior", to: "principal_engineer").levels).to eq({})
  end
end
