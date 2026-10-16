require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261016140000_repeat_track_chosen_at_backfill.rb")
require migration_path.to_s

RSpec.describe RepeatTrackChosenAtBackfill do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  it "marks an account that answered the old welcome page after the first backfill, and keeps every recorded time" do
    created = Time.utc(2026, 10, 15, 12)
    answered_late = User.create!(email: "late@example.com", name: "Late", created_at: created)
    write_learning_track(answered_late, "none")
    recorded = Time.utc(2026, 10, 16, 9)
    chosen = User.create!(email: "chosen@example.com", name: "Chosen", track_chosen_at: recorded)
    write_learning_track(chosen, "none")
    undecided = User.create!(email: "new@example.com", name: "New")

    migrate(:up)

    expect(answered_late.reload.track_chosen_at).to eq(created)
    expect(chosen.reload.track_chosen_at).to eq(recorded)
    expect(undecided.reload.track_chosen_at).to be_nil
  end
end
