require "rails_helper"

RSpec.describe LevelSuggestionEvent, type: :model do
  let(:user) { create_user_with_key }

  def event(**attrs)
    described_class.new({ user: user, kind: "code_review", action: "dismissed" }.merge(attrs))
  end

  it "accepts each closed action with the source rule" do
    expect(event(action: "applied", source: "suggestion")).to be_valid
    expect(event(action: "applied", source: "setup_edit")).to be_valid
    expect(event(action: "dismissed")).to be_valid
    expect(event(action: "removed")).to be_valid
  end

  it "refuses an action, kind or source outside the closed lists" do
    expect(event(action: "ignored")).not_to be_valid
    expect(event(kind: "crossword")).not_to be_valid
    expect(event(action: "applied", source: "card")).not_to be_valid
  end

  it "requires a source on an applied row and refuses one elsewhere" do
    expect(event(action: "applied")).not_to be_valid
    expect(event(action: "dismissed", source: "suggestion")).not_to be_valid
  end

  it "stores counts that default to zero and keeps only a creation time" do
    row = event.tap(&:save!).reload

    expect(row).to have_attributes(window_size: 0, favourable: 0, too_hard_latest3: 0, newest_result_on: nil)
    expect(described_class.column_names).to include("created_at")
    expect(described_class.column_names).not_to include("updated_at")
  end

  it "goes with the account when a user row is destroyed" do
    event.save!

    expect { user.destroy! }.to change(described_class, :count).by(-1)
  end

  describe ".applied_rows" do
    around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

    def rows(before:, after:)
      described_class.applied_rows(user, before_rungs: before, after_rungs: after,
                                         locked: [], cutoffs: {}, suggestions_on: true)
    end

    it "builds nothing and reads no evidence when no rung changed" do
      expect(LevelSuggestion::Evidence).not_to receive(:for)

      expect(rows(before: { "code_review" => "junior" }, after: { "code_review" => "junior" })).to eq([])
    end

    it "counts evidence at the level the kind moved from" do
      reviewed_level_days(user, "code_review", "junior", 3, self: "too_hard", ai: "developing")
      reviewed_level_day(user, Date.current - 5, { "code_review" => { rung: "mid_level" } })

      row = rows(before: { "code_review" => "junior" }, after: { "code_review" => "mid_level" }).sole

      expect(row).to include(kind: "code_review", action: "applied", source: "setup_edit",
                             from_level: "junior", to_level: "mid_level", window_size: 3,
                             favourable: 0, too_hard_latest3: 3, newest_result_on: Date.current)
    end

    it "builds one row for each kind whose rung moved and none for the rest" do
      before = ExerciseSection.keys.index_with { "junior" }

      kinds = rows(before: before, after: before.merge("pattern" => "senior", "architecture" => "mid_level")).map { _1[:kind] }

      expect(kinds).to contain_exactly("pattern", "architecture")
    end
  end
end
