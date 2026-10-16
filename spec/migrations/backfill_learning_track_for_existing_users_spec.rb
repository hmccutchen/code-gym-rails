require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261001120100_backfill_learning_track_for_existing_users.rb")
require migration_path.to_s

RSpec.describe BackfillLearningTrackForExistingUsers do
  def account(email, learning_track)
    User.create!(email: email, name: "Account").tap { |user| write_learning_track(user, learning_track) }
  end

  it "marks every undecided account none and leaves decided accounts alone" do
    undecided = account("undecided@example.com", nil)
    anonymized = account("anonymized@example.com", nil).tap { |user| user.update_column(:anonymized_at, Time.current) }
    on_track = account("junior@example.com", "junior")
    declined = account("none@example.com", "none")

    described_class.new.up

    expect(read_learning_track(undecided)).to eq("none")
    expect(read_learning_track(anonymized)).to eq("none")
    expect(read_learning_track(on_track)).to eq("junior")
    expect(read_learning_track(declined)).to eq("none")
  end

  it "does nothing on the way down" do
    user = account("kept@example.com", "none")

    described_class.new.down

    expect(read_learning_track(user)).to eq("none")
  end
end
