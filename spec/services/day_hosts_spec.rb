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

  # Only a schema_review code_review offers the data-modeling concepts, so
  # the day's mode decides whether code_review can host one.
  it "reads code_review's vocabulary for the day's mode" do
    concept = AiService::DATA_MODELING_CONCEPTS.first

    expect(hosts.can_tag?(ExerciseSection::CodeReview, concept, "ruby_rails")).to be(false)
    expect(described_class.new("ruby_rails", mode: :schema_review).can_tag?(ExerciseSection::CodeReview, concept, "ruby_rails")).to be(true)
  end

  it "lists the kinds that can tag a concept, in the order given" do
    kinds = [ ExerciseSection::Architecture, ExerciseSection::Challenge, ExerciseSection::CodeReview ]

    expect(hosts.hosts(kinds, "n_plus_one", "ruby_rails")).to eq([ ExerciseSection::Challenge, ExerciseSection::CodeReview ])
  end
end
