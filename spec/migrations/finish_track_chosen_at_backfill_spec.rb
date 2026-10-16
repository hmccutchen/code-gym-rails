require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261017060000_finish_track_chosen_at_backfill.rb")
require migration_path.to_s

RSpec.describe FinishTrackChosenAtBackfill do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  it "marks an account that answered the old welcome page in the last deploy gap, and keeps every recorded time" do
    created = Time.utc(2026, 10, 16, 2)
    answered_late = User.create!(email: "late@example.com", name: "Late", created_at: created)
    write_learning_track(answered_late, "none")
    recorded = Time.utc(2026, 10, 16, 9)
    chosen = User.create!(email: "chosen@example.com", name: "Chosen", track_chosen_at: recorded)
    write_learning_track(chosen, "none")
    undecided = User.create!(email: "new@example.com", name: "New")

    migrate(:up)

    expect(answered_late.reload.track_chosen_at).to eq(created)
    expect(answered_late.first_run?).to be false
    expect(chosen.reload.track_chosen_at).to eq(recorded)
    expect(undecided.reload.track_chosen_at).to be_nil
  end
end
