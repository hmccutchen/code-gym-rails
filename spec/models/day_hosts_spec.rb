require "rails_helper"

RSpec.describe DayHosts do
  let(:hosts) { described_class.new("ruby_rails", mode: :application_code) }

  it "lets a kind tag a concept its bucket records and its vocabulary offers" do
    expect(hosts.can_tag?(ExerciseSection::Challenge, "n_plus_one", "ruby_rails")).to be(true)
  end

  it "refuses a concept recorded under another bucket" do
    expect(hosts.can_tag?(ExerciseSection::Challenge, "service_boundaries", "architecture")).to be(false)
    expect(hosts.can_tag?(ExerciseSection::Architecture, "service_boundaries", "architecture")).to be(true)
  end

  # Only a schema_review code_review offers the data-modeling concepts.
  it "reads code_review's vocabulary for the day's mode" do
    concept = ConceptVocabulary::DATA_MODELING_CONCEPTS.first

    expect(hosts.can_tag?(ExerciseSection::CodeReview, concept, "ruby_rails")).to be(false)
    expect(described_class.new("ruby_rails", mode: :schema_review).can_tag?(ExerciseSection::CodeReview, concept, "ruby_rails")).to be(true)
  end

  it "refuses the week's featured concept to a kind that hides its concept, and leaves it to a kind that shows it" do
    plan_review = ConceptVocabulary::PLAN_REVIEW_CONCEPTS.first
    featured = FeaturedConcept.new(concept: plan_review, bucket: "plan_review")
    featuring = described_class.new("ruby_rails", mode: :application_code, featured: featured)

    expect(hosts.can_tag?(ExerciseSection::PlanReview, plan_review, "plan_review")).to be(true)
    expect(featuring.can_tag?(ExerciseSection::PlanReview, plan_review, "plan_review")).to be(false)
    expect(featuring.can_tag?(ExerciseSection::PlanReview, ConceptVocabulary::PLAN_REVIEW_CONCEPTS.second, "plan_review")).to be(true)

    memoization = FeaturedConcept.new(concept: "memoization", bucket: "ruby_rails")
    expect(described_class.new("ruby_rails", mode: :application_code, featured: memoization)
      .can_tag?(ExerciseSection::Challenge, "memoization", "ruby_rails")).to be(true)
  end

  it "lets code_review tag nothing on a bug_hunt day, since that section is not mastery evidence" do
    bug_hunt = described_class.new("ruby_rails", mode: :bug_hunt)

    BugHuntGotchas.concepts("ruby_rails").each do |concept|
      expect(bug_hunt.can_tag?(ExerciseSection::CodeReview, concept, "ruby_rails")).to be(false)
    end
    expect(bug_hunt.can_tag?(ExerciseSection::Challenge, "memoization", "ruby_rails")).to be(true)
  end

  it "lets no kind tag the picked gotcha's concept on a bug_hunt day" do
    gotcha   = BugHuntGotchas.find("rb_memo_falsy")
    bug_hunt = described_class.new("ruby_rails", mode: :bug_hunt, gotcha: gotcha)

    expect(bug_hunt.can_tag?(ExerciseSection::Pattern, "memoization", "ruby_rails")).to be(false)
    expect(bug_hunt.can_tag?(ExerciseSection::Pattern, "service_objects", "ruby_rails")).to be(true)
  end

  it "reads the strictest vocabulary, which every rung's vocabulary contains on every mode and trap" do
    %w[ruby_rails javascript].each do |language|
      days = DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys.map { |mode| [ mode, nil ] } +
             BugHuntGotchas.for_language(language).map { |gotcha| [ :bug_hunt, gotcha ] }
      ExerciseSection.all.product(KindDifficulty::LEVELS, days).each do |kind, rung, (mode, gotcha)|
        plain = ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, gotcha: gotcha)
        expect(plain - ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, rung: rung, gotcha: gotcha))
          .to be_empty, "#{kind.key} at #{rung} in #{language}, #{mode} #{gotcha&.id}"
      end
    end
  end

  it "lists the kinds that can tag a concept, in the order given" do
    kinds = [ ExerciseSection::Architecture, ExerciseSection::Challenge, ExerciseSection::CodeReview ]

    expect(hosts.hosts(kinds, "n_plus_one", "ruby_rails")).to eq([ ExerciseSection::Challenge, ExerciseSection::CodeReview ])
  end
end
