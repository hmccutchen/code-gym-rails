require "rails_helper"

RSpec.describe TrackGraduation do
  let(:today) { Date.new(2026, 10, 14) }

  def result(days_ago, level: "junior", ai: "solid", self_rating: "right_level")
    described_class::Result.new(date: today - days_ago, level: level, ai_rating: ai, self_rating: self_rating)
  end

  def good(n, level: "junior", from: 0) = Array.new(n) { |i| result(from + i, level: level) }
  def hard(days_ago, level: "senior", ai: "developing") = result(days_ago, level: level, ai: ai, self_rating: "too_hard")
  def cutoff(level, days_ago) = { "level" => level, "through" => (today - days_ago).iso8601 }
  def kinds_in(proposal) = proposal ? proposal.steps.map(&:kind) : []
  def junior_everywhere = ExerciseSection.keys.index_with { "junior" }

  def step(kind, from:, to:, results:, favourable:, too_hard:)
    described_class::Step.new(kind: kind, from: from, to: to, results_at_level: results,
                              favourable: favourable, too_hard: too_hard)
  end

  def propose(levels: junior_everywhere, locked: [], results: {}, cutoffs: {})
    described_class.proposal(levels: levels, locked: locked, results: results, cutoffs: cutoffs)
  end

  describe "constants" do
    it "climbs junior, mid-level, senior and leaves principal engineer out" do
      expect(described_class::LADDER).to eq(%w[junior mid_level senior])
    end

    it "states the rule's numbers in one place" do
      expect(described_class::WINDOW).to eq(5)
      expect(described_class::FAVOURABLE_NEEDED).to eq(4)
      expect([ described_class::VETO_WINDOW, described_class::VETO_TOO_HARD ]).to eq([ 3, 2 ])
      expect([ described_class::STEP_BACK_WINDOW, described_class::STEP_BACK_TOO_HARD ]).to eq([ 3, 2 ])
    end

    it "uses one too_hard window for both directions, which the summary's single count relies on" do
      expect(described_class::VETO_WINDOW).to eq(described_class::STEP_BACK_WINDOW)
    end
  end

  describe "result ratings" do
    it "is favourable on an AI rating of solid or better, whatever the self-rating" do
      %w[solid strong].product([ "too_easy", "right_level", "too_hard", nil ]).each do |ai, rating|
        expect(result(0, ai: ai, self_rating: rating)).to be_favourable
      end
      [ "beginner", "developing", nil, "unknown" ].each do |ai|
        expect(result(0, ai: ai)).not_to be_favourable
      end
    end

    it "reads struggle only from an explicit too_hard self-rating" do
      expect(result(0, ai: nil, self_rating: "too_hard")).to be_too_hard
      [ "too_easy", "right_level", nil, "unknown" ].each do |rating|
        expect(result(0, self_rating: rating)).not_to be_too_hard
      end
    end
  end

  describe "walkthrough A: three results or fewer per kind" do
    it "offers nothing" do
      results = {
        "code_review" => good(3),
        "design_comparison" => [ result(0, ai: "developing"), result(1), result(2) ],
        "pattern" => Array.new(3) { |i| result(i, ai: "strong", self_rating: "too_easy") },
        "challenge" => [ result(0, ai: "beginner", self_rating: "too_hard") ],
        "security_review" => [ result(0, ai: "strong"), result(1, ai: "strong", self_rating: "too_hard"), result(2, ai: "strong") ],
        "plan_review" => good(2)
      }

      expect(propose(results: results)).to be_nil
    end
  end

  describe "walkthrough B: five results per kind" do
    let(:security_review) do
      [ result(0, ai: "strong"), result(1, ai: "strong", self_rating: "too_hard") ] +
        Array.new(3) { |i| result(i + 2, ai: "strong") }
    end
    let(:results) do
      {
        "code_review" => good(5),
        "design_comparison" => [ result(0, ai: "developing") ] + good(4, from: 1),
        "pattern" => Array.new(5) { |i| result(i, ai: "strong", self_rating: "too_easy") },
        "challenge" => [ result(0, ai: "beginner", self_rating: "too_hard") ],
        "security_review" => security_review,
        "plan_review" => good(2)
      }
    end

    it "offers every qualifying kind together, one rung up, with the counts the rule read" do
      proposal = propose(results: results)

      expect(proposal.basis).to eq(:own)
      expect(proposal.steps).to eq([
        step("code_review", from: "junior", to: "mid_level", results: 5, favourable: 5, too_hard: 0),
        step("design_comparison", from: "junior", to: "mid_level", results: 5, favourable: 4, too_hard: 0),
        step("pattern", from: "junior", to: "mid_level", results: 5, favourable: 5, too_hard: 0),
        step("security_review", from: "junior", to: "mid_level", results: 5, favourable: 5, too_hard: 1)
      ])
    end

    it "vetoes a kind with two too_hard self-ratings in its latest three" do
      results["security_review"] = [ result(0, ai: "strong", self_rating: "too_hard") ] + security_review.drop(1)

      expect(kinds_in(propose(results: results))).to eq(%w[code_review design_comparison pattern])
    end
  end

  describe "step up" do
    it "needs five results at the level" do
      expect(propose(results: { "code_review" => good(4) })).to be_nil
      expect(kinds_in(propose(results: { "code_review" => good(5) }))).to eq([ "code_review" ])
    end

    it "needs four of the five favourable" do
      four = [ result(0, ai: "developing") ] + good(4, from: 1)
      three = [ result(0, ai: "developing"), result(1, ai: "beginner") ] + good(3, from: 2)

      expect(kinds_in(propose(results: { "code_review" => four }))).to eq([ "code_review" ])
      expect(propose(results: { "code_review" => three })).to be_nil
    end

    it "reads only the latest five" do
      results = good(5) + [ result(5, ai: "beginner"), result(6, ai: "beginner") ]
      expect(propose(results: { "code_review" => results }).steps.sole).to have_attributes(results_at_level: 7, favourable: 5)
    end

    it "is not vetoed by two too_hard results outside the latest three" do
      results = good(3) + [ result(3, self_rating: "too_hard"), result(4, self_rating: "too_hard") ]
      expect(propose(results: { "code_review" => results }).steps.sole.too_hard).to eq(0)
    end

    it "filters other levels before taking the window" do
      results = [ hard(0) ] + good(2, from: 1) + [ hard(3, level: "mid_level") ] + good(3, from: 4)
      expect(propose(results: { "code_review" => results }).steps.sole.results_at_level).to eq(5)
    end
  end

  describe "the ladder" do
    it "moves junior to mid-level and mid-level to senior" do
      levels = junior_everywhere.merge("code_review" => "mid_level")
      proposal = propose(levels: levels, results: { "code_review" => good(5, level: "mid_level") })

      expect(proposal.steps.sole).to have_attributes(from: "mid_level", to: "senior")
    end

    it "offers no step up from senior" do
      levels = junior_everywhere.merge("code_review" => "senior")
      expect(propose(levels: levels, results: { "code_review" => good(5, level: "senior") })).to be_nil
    end

    it "never treats principal engineer as a candidate in either direction" do
      levels = junior_everywhere.merge("code_review" => "principal_engineer")
      results = { "code_review" => good(5, level: "principal_engineer") }
      expect(propose(levels: levels, results: results)).to be_nil

      results = { "code_review" => [ hard(0, level: "principal_engineer"), hard(1, level: "principal_engineer") ] }
      expect(propose(levels: levels, results: results)).to be_nil
    end

    it "skips locked, untargeted and unknown kinds" do
      levels = { "code_review" => "junior", "pattern" => "unknown", "missing" => "junior" }
      results = levels.keys.index_with { good(5) }.merge("challenge" => good(5))
      expect(propose(levels: levels, locked: [ "code_review" ], results: results)).to be_nil
    end
  end

  describe "step back" do
    let(:levels) { junior_everywhere.merge("architecture" => "senior") }

    it "moves one rung down on two too_hard among the latest three" do
      results = { "architecture" => [ hard(0), result(1, level: "senior"), hard(2) ] }
      proposal = propose(levels: levels, results: results)

      expect(proposal.basis).to eq(:struggling)
      expect(proposal.steps).to eq([
        step("architecture", from: "senior", to: "mid_level", results: 3, favourable: 1, too_hard: 2)
      ])
    end

    it "is vetoed when the AI rated every too_hard result solid or better" do
      results = { "architecture" => [ hard(0, ai: "strong"), result(1, level: "senior"), hard(2, ai: "solid") ] }
      expect(propose(levels: levels, results: results)).to be_nil
    end

    it "is not vetoed when one too_hard result was rated below solid" do
      results = { "architecture" => [ hard(0, ai: "strong"), hard(1) ] }
      expect(propose(levels: levels, results: results).basis).to eq(:struggling)
    end

    it "does not move on one too_hard among the latest three" do
      results = { "architecture" => [ hard(0), result(1, level: "senior"), result(2, level: "senior") ] }
      expect(propose(levels: levels, results: results)).to be_nil
    end

    it "qualifies on two of two when only two exist" do
      expect(propose(levels: levels, results: { "architecture" => [ hard(0), hard(1) ] }).basis).to eq(:struggling)
    end

    it "moves mid-level to junior" do
      levels = junior_everywhere.merge("architecture" => "mid_level")
      results = { "architecture" => [ hard(0, level: "mid_level"), hard(1, level: "mid_level") ] }
      expect(propose(levels: levels, results: results).steps.sole).to have_attributes(from: "mid_level", to: "junior")
    end

    it "never moves down from junior" do
      results = { "architecture" => [ hard(0, level: "junior"), hard(1, level: "junior"), hard(2, level: "junior") ] }
      expect(propose(results: results)).to be_nil
    end

    it "ignores too_hard outside the latest three or at another level" do
      results = { "architecture" => [ hard(0, level: "junior") ] + good(3, level: "senior", from: 1) + [ hard(4), hard(5) ] }
      expect(propose(levels: levels, results: results)).to be_nil
    end

    it "comes before a step up" do
      results = { "architecture" => [ hard(0), hard(1) ], "code_review" => good(5) }
      expect(propose(levels: levels, results: results).basis).to eq(:struggling)
    end

    it "is shown alone, for the first kind in registry order" do
      levels = junior_everywhere.merge("architecture" => "senior", "pattern" => "senior")
      results = { "architecture" => [ hard(0), hard(1) ], "pattern" => [ hard(0), hard(1) ] }
      expect(kinds_in(propose(levels: levels, results: results))).to eq([ "pattern" ])
    end

    it "skips a locked kind" do
      results = { "architecture" => [ hard(0), hard(1) ] }
      expect(propose(levels: levels, locked: [ "architecture" ], results: results)).to be_nil
    end
  end

  describe "no bundle" do
    it "never offers a kind on no results of its own" do
      levels = junior_everywhere.merge("code_review" => "senior")
      expect(propose(levels: levels)).to be_nil

      proposal = propose(results: { "code_review" => good(5) })
      expect(kinds_in(proposal)).to eq([ "code_review" ])
    end

    it "never uses a :led basis" do
      levels = junior_everywhere.merge("code_review" => "senior", "architecture" => "senior")
      [ { "pattern" => good(5) }, { "architecture" => [ hard(0), hard(1) ] } ].each do |results|
        expect(%i[own struggling]).to include(propose(levels: levels, results: results).basis)
      end
    end
  end

  describe "kinds at different levels" do
    it "offers only the group sharing the first qualifying kind's level" do
      levels = junior_everywhere.merge("pattern" => "mid_level")
      results = { "code_review" => good(5), "pattern" => good(5, level: "mid_level"), "challenge" => good(5) }
      expect(kinds_in(propose(levels: levels, results: results))).to eq(%w[code_review challenge])

      levels = junior_everywhere.merge("design_comparison" => "mid_level")
      results = { "design_comparison" => good(5, level: "mid_level"), "pattern" => good(5) }
      proposal = propose(levels: levels, results: results)
      expect(proposal.steps.map { |item| [ item.kind, item.to ] }).to eq([ %w[design_comparison senior] ])
    end
  end

  describe "cutoffs" do
    it "re-offers only after five results strictly newer than the cutoff at the current level" do
      cutoffs = { "code_review" => cutoff("junior", 5) }
      expect(propose(results: { "code_review" => good(10, from: 1) }, cutoffs: cutoffs)).to be_nil
      expect(kinds_in(propose(results: { "code_review" => good(10) }, cutoffs: cutoffs))).to eq([ "code_review" ])
    end

    it "never counts results at another level, even newer ones" do
      cutoffs = { "code_review" => cutoff("junior", 5) }
      results = { "code_review" => good(5, level: "mid_level") + good(5, from: 6) }
      expect(propose(results: results, cutoffs: cutoffs)).to be_nil
    end

    it "ignores a cutoff recorded at another level" do
      cutoffs = { "code_review" => cutoff("mid_level", 0) }
      expect(kinds_in(propose(results: { "code_review" => good(5) }, cutoffs: cutoffs))).to eq([ "code_review" ])
    end

    it "keeps a dismissed kind dismissed however many results another kind collects" do
      cutoffs = { "design_comparison" => cutoff("junior", 5) }
      results = { "design_comparison" => good(5, from: 6), "code_review" => good(10) }
      expect(kinds_in(propose(results: results, cutoffs: cutoffs))).to eq([ "code_review" ])
    end

    it "needs two newer too_hard results for a step back" do
      levels = junior_everywhere.merge("architecture" => "senior")
      cutoffs = { "architecture" => cutoff("senior", 2) }
      expect(propose(levels: levels, results: { "architecture" => [ hard(0), hard(2) ] }, cutoffs: cutoffs)).to be_nil
      proposal = propose(levels: levels, results: { "architecture" => [ hard(0), hard(1), hard(2) ] }, cutoffs: cutoffs)
      expect(proposal.steps.sole.results_at_level).to eq(2)
    end

    it "reads a malformed entry as no cutoff" do
      [ nil, "junk", [], {}, { "through" => today.iso8601 }, { "level" => "junior" },
        { "level" => "junior", "through" => "not a date" },
        { "level" => "junior", "through" => "2026-02-30" } ].each do |entry|
        expect(propose(results: { "code_review" => good(5) }, cutoffs: { "code_review" => entry }).basis).to eq(:own)
      end
    end
  end

  describe ".summary" do
    it "counts what the rule reads at the given level after its cutoff" do
      results = { "code_review" => [ result(0, level: "mid_level"), result(1, ai: "developing", self_rating: "too_hard"),
                                     result(2, ai: "strong", self_rating: "too_hard") ] + good(5, from: 3) }
      summary = described_class.summary(kind: "code_review", level: "junior", results: results,
                                        cutoffs: { "code_review" => cutoff("junior", 6) })

      expect(summary).to eq(described_class::Summary.new(window_size: 5, favourable: 4, too_hard_latest3: 2,
                                                         newest_result_on: today - 1))
    end

    it "ignores a cutoff at another level" do
      summary = described_class.summary(kind: "code_review", level: "junior", results: { "code_review" => good(7) },
                                        cutoffs: { "code_review" => cutoff("mid_level", 0) })
      expect(summary).to have_attributes(window_size: 5, favourable: 5, newest_result_on: today)
    end

    it "is empty for a kind with no results" do
      summary = described_class.summary(kind: "pattern", level: "senior", results: {}, cutoffs: {})
      expect(summary).to eq(described_class::Summary.new(window_size: 0, favourable: 0, too_hard_latest3: 0,
                                                         newest_result_on: nil))
    end
  end

  it "does not flap across a mid-level → junior → mid-level cycle" do
    levels = junior_everywhere.merge("architecture" => "mid_level")
    struggle = [ hard(10, level: "mid_level"), hard(11, level: "mid_level") ]
    old_junior = good(5, from: 12)
    history = { "architecture" => struggle + old_junior }
    expect(propose(levels: levels, results: history).basis).to eq(:struggling)

    levels = levels.merge("architecture" => "junior")
    cutoffs = { "architecture" => cutoff("junior", 9) }
    expect(propose(levels: levels, results: history, cutoffs: cutoffs)).to be_nil

    history = { "architecture" => good(5, from: 4) + struggle + old_junior }
    proposal = propose(levels: levels, results: history, cutoffs: cutoffs)
    expect([ proposal.basis, kinds_in(proposal) ]).to eq([ :own, [ "architecture" ] ])

    levels = levels.merge("architecture" => "mid_level")
    cutoffs = { "architecture" => cutoff("mid_level", 3) }
    expect(propose(levels: levels, results: history, cutoffs: cutoffs)).to be_nil
    expect(propose(levels: levels, results: history).basis).to eq(:struggling)
  end

  it "reaches senior everywhere by applying each proposal in turn" do
    levels = junior_everywhere
    results = ExerciseSection.keys.index_with { good(5) + good(5, level: "mid_level", from: 5) }

    (described_class::LADDER.size * ExerciseSection.keys.size).times do
      proposal = propose(levels: levels, results: results)
      break unless proposal

      proposal.steps.each { |item| levels = levels.merge(item.kind => item.to) }
    end

    expect(levels.values.uniq).to eq([ "senior" ])
    expect(propose(levels: levels, results: results)).to be_nil
  end

  it "does not mutate its plain inputs" do
    levels = junior_everywhere.freeze
    locked = [].freeze
    results = { "code_review" => good(5).freeze }.freeze
    cutoffs = { "code_review" => cutoff("junior", 5).freeze }.freeze
    expect(propose(levels: levels, locked: locked, results: results, cutoffs: cutoffs).basis).to eq(:own)
  end
end
