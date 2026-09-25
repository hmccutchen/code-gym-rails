require "rails_helper"

RSpec.describe ConceptHosts do
  let(:user) { User.new(language: "ruby_rails") }
  let(:hosts) { described_class.for(user) }

  it "hosts a language concept in the fixed language sections and the language thirds" do
    kinds = hosts.kinds_for("n_plus_one", "ruby_rails").map(&:key)

    expect(kinds).to include("code_review", "pattern", "challenge")
    expect(kinds).not_to include("architecture", "plan_review")
  end

  it "hosts a data-modeling concept in code_review through its schema mode" do
    expect(hosts.kinds_for("wrong_cardinality", "ruby_rails").map(&:key)).to include("code_review")
  end

  it "hosts an architecture concept only in the architecture third" do
    expect(hosts.kinds_for("sync_vs_async", "architecture").map(&:key)).to eq([ "architecture" ])
  end

  it "answers nothing for a concept outside the user's languages" do
    expect(hosts.kinds_for("prototype_chain", "javascript")).to eq([])
  end

  it "covers both languages for a mixed user" do
    mixed = described_class.for(User.new(language: "mixed"))

    expect(mixed.kinds_for("prototype_chain", "javascript").map(&:key)).to include("code_review")
  end
end
