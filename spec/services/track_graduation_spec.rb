require "rails_helper"

RSpec.describe TrackGraduation do
  let(:today) { Date.new(2026, 10, 14) }
  let(:lead) { ExerciseSection.learning_track_lead.key }

  def result(days_ago, level: "junior", ai: "solid", self_rating: "right_level")
    described_class::Result.new(date: today - days_ago, level: level, ai_rating: ai, self_rating: self_rating)
  end

  def good(n, level: "junior", from: 0) = Array.new(n) { |i| result(from + i, level: level) }
  def too_hard(days_ago, level: "senior") = result(days_ago, level: level, self_rating: "too_hard")
  def cutoff(level, days_ago) = { "level" => level, "through" => (today - days_ago).iso8601 }
  def kinds_in(proposal) = proposal ? proposal.steps.map(&:kind) : []
  def junior_everywhere = ExerciseSection.keys.index_with { "junior" }

  def propose(levels: junior_everywhere, locked: [], results: {}, cutoffs: {})
    described_class.proposal(levels: levels, locked: locked, results: results, cutoffs: cutoffs)
  end

  describe "result ratings" do
    it "uses the same favourable self-ratings as a daily response" do
      expect(DailyResponse::SELF_RATING_FAVORABLE).to eq(%w[too_easy right_level])
      DailyResponse::SELF_RATINGS.each do |rating|
        response = DailyResponse.new(section_ratings: { lead => rating })
        expect(result(0, self_rating: rating).favourable?).to eq(response.self_rating_favorable?(lead))
      end
    end

    it "requires both a favourable AI rating and a favourable self-rating" do
      %w[solid strong].product(%w[too_easy right_level]).each do |ai, rating|
        expect(result(0, ai: ai, self_rating: rating)).to be_favourable
      end
      [ "beginner", "developing", nil, "unknown" ].each do |ai|
        expect(result(0, ai: ai)).not_to be_favourable
      end
      [ "too_hard", nil, "unknown" ].each do |rating|
        expect(result(0, self_rating: rating)).not_to be_favourable
      end
    end

    it "reads struggle only from an explicit too_hard self-rating" do
      expect(result(0, ai: nil, self_rating: "too_hard")).to be_too_hard
      [ "too_easy", "right_level", nil, "unknown" ].each do |rating|
        expect(result(0, self_rating: rating)).not_to be_too_hard
      end
    end
  end

  describe "forward on own results" do
    it "does not propose on two favourable results" do
      expect(propose(results: { lead => good(2) })).to be_nil
    end

    it "proposes on three" do
      proposal = propose(results: { lead => good(3) })

      expect(proposal.basis).to eq(:own)
      expect(proposal.steps).to eq([ described_class::Step.new(kind: lead, from: "junior", to: "senior", results_at_level: 3) ])
    end

    it "is blocked by an unfavourable AI rating among the last three" do
      results = [ result(0), result(1, ai: "developing"), result(2), result(3) ]
      expect(propose(results: { lead => results })).to be_nil
    end

    it "is blocked by too_hard even with a strong AI rating" do
      results = [ result(0), result(1, ai: "strong", self_rating: "too_hard"), result(2) ]
      expect(propose(results: { lead => results })).to be_nil
    end

    it "ignores an unfavourable result outside the last three and counts all results at the level" do
      proposal = propose(results: { lead => good(3) + [ result(3, ai: "beginner") ] })
      expect(proposal.steps.first.results_at_level).to eq(4)
    end

    it "ignores results at another level" do
      expect(propose(results: { lead => good(3, level: "senior") })).to be_nil
    end

    it "filters other levels before taking the window" do
      results = [ too_hard(0), result(1), too_hard(2), result(3), result(4) ]
      expect(propose(results: { lead => results }).steps.first.results_at_level).to eq(3)
    end

    it "chooses one kind in registry order rather than results or target order" do
      keys = ExerciseSection.keys.first(3).reverse
      proposal = propose(levels: keys.index_with { "junior" }, results: keys.index_with { good(3) })
      expect(kinds_in(proposal)).to eq([ lead ])
    end
  end

  describe "led by the lead kind" do
    let(:lead_senior) { junior_everywhere.merge(lead => "senior") }

    it "bundles every other junior kind, including ones with no results" do
      proposal = propose(levels: lead_senior)

      expect(proposal.basis).to eq(:led)
      expect(proposal.steps).to eq((ExerciseSection.keys - [ lead ]).map do |key|
        described_class::Step.new(kind: key, from: "junior", to: "senior", results_at_level: 0)
      end)
    end

    it "leaves out a kind with one unfavourable self-rating among its last three" do
      proposal = propose(levels: lead_senior, results: { "architecture" => [ result(0, self_rating: "too_hard") ] })
      expect(kinds_in(proposal)).not_to include("architecture")
    end

    it "leaves out a kind with an unfavourable AI rating" do
      proposal = propose(levels: lead_senior, results: { "architecture" => [ result(0, ai: "developing") ] })
      expect(kinds_in(proposal)).not_to include("architecture")
    end

    it "includes a kind with fewer than three favourable results and ignores other levels" do
      proposal = propose(levels: lead_senior, results: { "architecture" => [ too_hard(0) ] + good(2, from: 1) })
      step = proposal.steps.find { |item| item.kind == "architecture" }
      expect(step.results_at_level).to eq(2)
    end

    it "does not fire while the lead is junior or has no valid target" do
      expect(propose).to be_nil
      expect(propose(levels: junior_everywhere.except(lead))).to be_nil
      expect(propose(levels: junior_everywhere.merge(lead => "unknown"))).to be_nil
    end

    it "follows a lead set to principal_engineer by hand" do
      expect(propose(levels: junior_everywhere.merge(lead => "principal_engineer")).basis).to eq(:led)
    end

    it "can follow a locked lead without changing the lead" do
      expect(kinds_in(propose(levels: lead_senior, locked: [ lead ]))).to eq(ExerciseSection.keys - [ lead ])
    end

    it "proposes a kind that qualifies on its own results alone, outside any bundle" do
      proposal = propose(levels: lead_senior, results: { "pattern" => good(3) })
      expect(proposal.basis).to eq(:own)
      expect(kinds_in(proposal)).to eq([ "pattern" ])
    end
  end

  describe "back from senior" do
    let(:levels) { junior_everywhere.merge("architecture" => "senior") }

    it "does not propose on one too_hard among the last three" do
      results = { "architecture" => [ too_hard(0), result(1, level: "senior"), result(2, level: "senior") ] }
      expect(propose(levels: levels, results: results)).to be_nil
    end

    it "proposes on two" do
      results = { "architecture" => [ too_hard(0), result(1, level: "senior"), too_hard(2) ] }
      proposal = propose(levels: levels, results: results)

      expect(proposal.basis).to eq(:struggling)
      expect(proposal.steps).to eq([ described_class::Step.new(kind: "architecture", from: "senior", to: "junior", results_at_level: 3) ])
    end

    it "proposes on two of two when only two exist" do
      expect(propose(levels: levels, results: { "architecture" => [ too_hard(0), too_hard(1) ] }).basis).to eq(:struggling)
    end

    it "ignores the AI rating" do
      results = { "architecture" => Array.new(3) { |i| result(i, level: "senior", ai: "beginner") } }
      expect(propose(levels: levels, results: results)).to be_nil
      results = { "architecture" => Array.new(2) { |i| result(i, level: "senior", ai: nil, self_rating: "too_hard") } }
      expect(propose(levels: levels, results: results).basis).to eq(:struggling)
    end

    it "ignores too_hard outside the last three or at another level" do
      results = { "architecture" => [ too_hard(0, level: "junior") ] + good(3, level: "senior", from: 1) + [ too_hard(4), too_hard(5) ] }
      expect(propose(levels: levels, results: results)).to be_nil
    end

    it "comes before an own-result forward step" do
      results = { "architecture" => [ too_hard(0), too_hard(1) ], lead => good(3) }
      expect(propose(levels: levels, results: results).basis).to eq(:struggling)
    end

    it "comes before a led bundle and chooses one kind in registry order" do
      levels = junior_everywhere.merge(lead => "senior", "architecture" => "senior", "pattern" => "senior")
      results = { "architecture" => [ too_hard(0), too_hard(1) ], "pattern" => [ too_hard(0), too_hard(1) ] }
      proposal = propose(levels: levels, results: results)
      expect(proposal.basis).to eq(:struggling)
      expect(kinds_in(proposal)).to eq([ "pattern" ])
    end
  end

  it "skips locked, untargeted, unknown and principal_engineer kinds for own steps" do
    levels = { lead => "junior", "pattern" => "principal_engineer", "architecture" => "unknown", "missing" => "junior" }
    results = levels.keys.index_with { good(3) }.merge("challenge" => good(3))
    expect(propose(levels: levels, locked: [ lead ], results: results)).to be_nil
  end

  it "skips locked, untargeted and principal_engineer kinds for led and back steps" do
    levels = { lead => "senior", "pattern" => "principal_engineer", "challenge" => "junior", "architecture" => "senior" }
    results = { "pattern" => [ too_hard(0, level: "principal_engineer"), too_hard(1, level: "principal_engineer") ],
                "architecture" => [ too_hard(0), too_hard(1) ] }
    expect(propose(levels: levels, locked: %w[challenge architecture], results: results)).to be_nil
  end

  describe "cutoffs" do
    it "hides a step until three results strictly newer than the cutoff exist" do
      cutoffs = { lead => cutoff("junior", 3) }
      expect(propose(results: { lead => good(3, from: 3) }, cutoffs: cutoffs)).to be_nil
      expect(propose(results: { lead => good(3, from: 1) }, cutoffs: cutoffs)).to be_nil
      expect(propose(results: { lead => good(3) }, cutoffs: cutoffs).basis).to eq(:own)
    end

    it "ignores a cutoff once the kind has left its level" do
      levels = junior_everywhere.merge(lead => "senior")
      results = { lead => [ too_hard(4), too_hard(5) ] }
      expect(propose(levels: levels, results: results, cutoffs: { lead => cutoff("junior", 3) }).basis).to eq(:struggling)
    end

    it "needs two newer too_hard results for a back step" do
      levels = junior_everywhere.merge("architecture" => "senior")
      cutoffs = { "architecture" => cutoff("senior", 2) }
      expect(propose(levels: levels, results: { "architecture" => [ too_hard(0), too_hard(2) ] }, cutoffs: cutoffs)).to be_nil
      proposal = propose(levels: levels, results: { "architecture" => [ too_hard(0), too_hard(1), too_hard(2) ] }, cutoffs: cutoffs)
      expect(proposal.steps.first.results_at_level).to eq(2)
    end

    it "needs three newer favourable lead results before a cut-off led kind returns" do
      levels = junior_everywhere.merge(lead => "senior")
      cutoffs = { "architecture" => cutoff("junior", 3) }
      [ [], good(2, level: "senior"), good(3, level: "senior", from: 1),
        [ result(0, level: "senior", ai: "beginner") ] + good(3, level: "senior", from: 1) ].each do |results|
        expect(kinds_in(propose(levels: levels, results: { lead => results }, cutoffs: cutoffs))).not_to include("architecture")
      end
      expect(kinds_in(propose(levels: levels, results: { lead => good(3, level: "senior") }, cutoffs: cutoffs)))
        .to include("architecture")
    end

    it "uses the led kind's cutoff and accepts lead results across levels" do
      levels = junior_everywhere.merge(lead => "senior")
      results = { lead => [ result(0, level: "senior"), result(1), result(2) ] }
      cutoffs = { "architecture" => cutoff("junior", 3), lead => cutoff("senior", 0) }
      expect(kinds_in(propose(levels: levels, results: results, cutoffs: cutoffs))).to include("architecture")
    end

    it "ignores own results before the cutoff but still blocks on a newer unfavourable result" do
      levels = junior_everywhere.merge(lead => "senior")
      cutoffs = { "architecture" => cutoff("junior", 3) }
      results = { lead => good(3, level: "senior"), "architecture" => [ result(3, ai: "beginner") ] }
      expect(kinds_in(propose(levels: levels, results: results, cutoffs: cutoffs))).to include("architecture")
      results["architecture"].unshift(result(0, ai: "beginner"))
      expect(kinds_in(propose(levels: levels, results: results, cutoffs: cutoffs))).not_to include("architecture")
    end

    it "reads a malformed entry as no cutoff" do
      [ nil, "junk", [], {}, { "through" => today.iso8601 }, { "level" => "junior" },
        { "level" => "junior", "through" => "not a date" },
        { "level" => "junior", "through" => "2026-02-30" } ].each do |entry|
        expect(propose(results: { lead => good(3) }, cutoffs: { lead => entry }).basis).to eq(:own)
      end
    end
  end

  it "does not flap across a full senior → junior → senior cycle" do
    levels = junior_everywhere.merge(lead => "senior", "architecture" => "senior")
    struggle = [ too_hard(10), too_hard(11) ]
    old_junior = good(3, from: 12)
    history = { "architecture" => struggle + old_junior }
    expect(propose(levels: levels, results: history).basis).to eq(:struggling)

    levels = levels.merge("architecture" => "junior")
    cutoffs = { "architecture" => cutoff("junior", 9) }
    expect(kinds_in(propose(levels: levels, results: history, cutoffs: cutoffs))).not_to include("architecture")

    history = { "architecture" => good(3, from: 6) + struggle + old_junior }
    proposal = propose(levels: levels, results: history, cutoffs: cutoffs)
    expect([ proposal.basis, kinds_in(proposal) ]).to eq([ :own, [ "architecture" ] ])

    levels = levels.merge("architecture" => "senior")
    cutoffs = { "architecture" => cutoff("senior", 5) }
    expect(kinds_in(propose(levels: levels, results: history, cutoffs: cutoffs))).not_to include("architecture")
    expect(propose(levels: levels, results: history).basis).to eq(:struggling)
  end

  it "reaches senior everywhere by applying each proposal in turn" do
    levels = junior_everywhere
    results = { lead => good(3) }

    ExerciseSection.keys.size.times do
      proposal = propose(levels: levels, results: results)
      break unless proposal

      proposal.steps.each { |step| levels = levels.merge(step.kind => step.to) }
    end

    expect(levels.values.uniq).to eq([ "senior" ])
    expect(propose(levels: levels, results: results)).to be_nil
  end

  it "does not mutate its plain inputs" do
    levels = junior_everywhere.freeze
    locked = [].freeze
    results = { lead => good(3).freeze }.freeze
    cutoffs = { lead => cutoff("junior", 3).freeze }.freeze
    expect(propose(levels: levels, locked: locked, results: results, cutoffs: cutoffs).basis).to eq(:own)
  end
end
