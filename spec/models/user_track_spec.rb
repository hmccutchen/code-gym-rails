require "rails_helper"

RSpec.describe User, "track", type: :model do
  around { |example| travel_to(Time.utc(2026, 10, 16, 15)) { example.run } }

  def new_account(**attrs)
    User.create!({ email: "new-#{SecureRandom.hex(3)}@example.com", name: "New", time_zone: "UTC" }.merge(attrs))
  end

  def chosen(**attrs) = new_account(track_chosen_at: 1.day.ago, **attrs)

  describe "#first_run?" do
    it "is true for a saved account with no choice and no exercise" do
      expect(new_account.first_run?).to be true
    end

    it "is false for an unsaved account" do
      expect(User.new.first_run?).to be false
    end

    it "is false once a choice is recorded, without querying exercises" do
      user = chosen
      expect(user).not_to receive(:daily_exercises)
      expect(user.first_run?).to be false
    end

    it "no longer reads learning_track, which the migrations folded into track_chosen_at" do
      user = new_account
      write_learning_track(user, "none")

      expect(user.reload.first_run?).to be true
    end

    it "is false once any exercise exists" do
      user = new_account
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
      expect(user.first_run?).to be false
    end
  end

  describe "#choose_track" do
    it "records the choice and its level, and no longer writes learning_track" do
      user = new_account
      user.choose_track("mid_level")
      user.save!

      expect(user.reload).to have_attributes(skill_level: "mid_level", track_chosen_at: Time.current)
      expect(user.first_run?).to be false
      expect(read_learning_track(user)).to be_nil
    end
  end

  it "ignores learning_track until the next release drops the column" do
    expect(User.column_names).not_to include("learning_track")
    expect(ActiveRecord::Base.connection.column_exists?(:users, :learning_track)).to be(true)
  end
end
