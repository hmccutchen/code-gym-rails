require "rails_helper"

RSpec.describe User, "daily section kinds" do
  let(:user) { User.create!(email: "daily-kinds@example.com", name: "Daily") }

  it "saves a full pair and the empty default" do
    expect(user.update(daily_section_kinds: %w[architecture code_review])).to be(true)
    expect(user.update(daily_section_kinds: [])).to be(true)
  end

  it "refuses each invalid shape on daily_section_kinds" do
    [ %w[pattern], %w[pattern pattern], %w[pattern retired_kind], %w[plan_review ambiguity_hunt], "pattern" ].each do |shape|
      user.daily_section_kinds = shape

      expect(user).not_to be_valid
      expect(user.errors[:daily_section_kinds]).to be_present, "expected #{shape.inspect} to be refused"
    end
  end

  it "refuses a new pair that leaves an optional slot with every kind excluded" do
    user.update!(excluded_section_kinds: %w[architecture security_review challenge])

    expect(user.update(daily_section_kinds: %w[parsons_problem code_review])).to be(false)
    expect(user.errors[:excluded_section_kinds]).to include("must leave at least one third section in rotation")
  end

  it "still refuses an exclusion change that empties a slot of the user's layout" do
    user.update!(daily_section_kinds: %w[parsons_problem code_review])

    expect(user.update(excluded_section_kinds: %w[architecture security_review challenge])).to be(false)
    expect(user.errors[:excluded_section_kinds]).to include("must leave at least one third section in rotation")
  end

  it "keeps a daily kind out of the kinds a weight or exclusion may name" do
    user.update!(daily_section_kinds: %w[challenge code_review])

    expect(user.send(:rotatable_keys)).not_to include("challenge")
    expect(user.update(section_kind_weights: { "challenge" => 2.0 })).to be(false)
    expect(user.update(section_kind_weights: { "architecture" => 2.0 })).to be(true)
  end

  it "keeps a weight and an exclusion stored on a kind before it became daily, and checks only new entries" do
    user.update!(section_kind_weights: { "challenge" => 2.0 }, excluded_section_kinds: %w[parsons_problem])
    user.update!(daily_section_kinds: %w[challenge parsons_problem])

    expect(user.update(section_kind_weights: { "challenge" => 2.0, "architecture" => 0.5 })).to be(true)
    expect(user.update(excluded_section_kinds: %w[parsons_problem security_review])).to be(true)
    expect(user.update(section_kind_weights: { "challenge" => 4.0, "architecture" => 0.5 })).to be(false)
    expect(user.reload.section_kind_weights).to eq("challenge" => 2.0, "architecture" => 0.5)
  end

  it "merges a daily kind's stored entries back into an Exercise mix save, which posts only the rows on screen" do
    user.update!(section_kind_weights: { "challenge" => 2.0 }, excluded_section_kinds: %w[parsons_problem])
    user.update!(daily_section_kinds: %w[challenge parsons_problem])

    attrs = user.keep_daily_kind_entries(section_kind_weights: { "architecture" => 0.5 }, excluded_section_kinds: [])

    expect(attrs).to eq(section_kind_weights: { "challenge" => 2.0, "architecture" => 0.5 },
                        excluded_section_kinds: %w[parsons_problem])
    expect(user.keep_daily_kind_entries(name: "Kept")).to eq(name: "Kept")
  end
end
