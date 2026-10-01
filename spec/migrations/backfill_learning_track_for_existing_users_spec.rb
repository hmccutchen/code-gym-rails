require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261001120100_backfill_learning_track_for_existing_users.rb")
require migration_path.to_s

RSpec.describe BackfillLearningTrackForExistingUsers do
  # A junior account needs a junior target, or the track ends itself on save.
  def account(email, learning_track)
    levels = learning_track == "junior" ? LearningTrack.preset_levels : {}
    User.create!(email: email, name: "Account", learning_track: learning_track, section_kind_levels: levels)
  end

  it "marks every undecided account none and leaves decided accounts alone" do
    undecided = account("undecided@example.com", nil)
    anonymized = account("anonymized@example.com", nil).tap { |user| user.update_column(:anonymized_at, Time.current) }
    on_track = account("junior@example.com", "junior")
    declined = account("none@example.com", "none")

    described_class.new.up

    expect(undecided.reload.learning_track).to eq("none")
    expect(anonymized.reload.learning_track).to eq("none")
    expect(on_track.reload.learning_track).to eq("junior")
    expect(declined.reload.learning_track).to eq("none")
  end

  it "leaves a backfilled account out of first run" do
    user = account("existing@example.com", nil)

    described_class.new.up

    expect(user.reload.first_run?).to be false
  end

  it "does nothing on the way down" do
    user = account("kept@example.com", "none")

    described_class.new.down

    expect(user.reload.learning_track).to eq("none")
  end
end
