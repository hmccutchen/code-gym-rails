require "rails_helper"

RSpec.describe LearnSearchHelper, type: :helper do
  it "joins the name, the shown group, the bucket and the synonyms, lowercased" do
    text = helper.learn_search_text("n_plus_one", bucket: "ruby_rails", group: "core")

    expect(text).to eq("n plus one core ruby/rails n+1 eager loading")
  end

  it "adds every glossary form of the name" do
    text = helper.learn_search_text("memoization", bucket: "ruby_rails", group: "core")

    expect(text).to include("memoized", "memoizing", "memoised")
  end

  it "uses the group's label, as its heading shows it" do
    text = helper.learn_search_text("god_object", bucket: "javascript", group: "code_smell")

    expect(text).to include("code smells", "javascript/react", "god class")
  end

  it "carries no group name when the page shows no group heading" do
    text = helper.learn_search_text("idempotency_at_scale", bucket: "architecture", group: nil)

    expect(text).to eq("idempotency at scale architecture")
  end

  it "builds a lesson's text the same way" do
    text = helper.learn_search_text("reading_unfamiliar_code", bucket: "ruby_rails", group: "meta_skill")

    expect(text).to eq("reading unfamiliar code reading and reasoning ruby/rails")
  end
end
