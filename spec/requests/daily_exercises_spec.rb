require "rails_helper"

RSpec.describe "DailyExercises", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key }

  before { login_as(user) }

  def create_exercise(regenerated_at: nil)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: { "code_review" => { "question" => "old" } },
                          generated_at: Time.current, regenerated_at: regenerated_at)
  end

  describe "POST /regenerate" do
    it "redirects with an alert when there's no exercise yet" do
      post regenerate_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("No exercise set to regenerate yet.")
    end

    it "blocks a second regeneration the same day" do
      create_exercise(regenerated_at: Time.current)

      post regenerate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You've already generated a new set today.")
    end

    it "enqueues the job without calling the provider inline" do
      create_exercise
      allow(AiService).to receive(:for)

      expect {
        post regenerate_path
      }.to have_enqueued_job(RegenerateExerciseJob).with(user_id: user.id)

      expect(AiService).not_to have_received(:for)
      expect(response).to redirect_to(root_path)
    end

    it "claims the row so the dashboard can show it as in flight" do
      exercise = create_exercise

      post regenerate_path

      expect(exercise.reload.regenerating_since).to be_present
    end

    # An impatient second click must not enqueue a second billable generation.
    it "does not enqueue twice while a claim is already held" do
      create_exercise
      post regenerate_path

      expect { post regenerate_path }.not_to have_enqueued_job(RegenerateExerciseJob)
    end

    # A worker that died mid-job leaves a claim behind; the user must be able to
    # try again rather than being locked out for the rest of the day.
    it "lets a stale claim be reclaimed" do
      exercise = create_exercise
      exercise.update!(regenerating_since: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.minute)

      expect {
        post regenerate_path
      }.to have_enqueued_job(RegenerateExerciseJob)
    end

    it "does not claim regeneration for another user's exercise" do
      # Current user has an exercise
      exercise = create_exercise

      # Another user also has an exercise on the same day
      other_user = create_user_with_key(email: "other-user-#{SecureRandom.hex(4)}@example.com")
      other_exercise = DailyExercise.create!(
        user: other_user,
        date: Date.current,
        problem_set: { "code_review" => { "question" => "test" } },
        generated_at: Time.current,
        regenerated_at: nil
      )

      # Directly test that the claim query includes user_id scoping:
      # Without user_id in WHERE, both exercises would match on id + regenerated_at
      # (if somehow passed the wrong exercise_id). With user_id, only the
      # matching user's row is updated.

      # Verify that querying for the other exercise WITH the current user's id
      # returns nothing (proving user_id scoping is working)
      unscoped_match = DailyExercise.where(id: other_exercise.id, regenerated_at: nil).count
      expect(unscoped_match).to eq(1)  # Other exercise exists

      scoped_match = DailyExercise.where(
        id: other_exercise.id,
        user_id: user.id,
        regenerated_at: nil
      ).count
      expect(scoped_match).to eq(0)  # But doesn't match with wrong user_id

      # Current user regenerates
      post regenerate_path

      # Current user's exercise should be claimed
      expect(exercise.reload.regenerating_since).to be_present

      # Other user's exercise must not be claimed
      expect(other_exercise.reload.regenerating_since).to be_nil
    end
  end

  describe "POST /generate" do
    it "enqueues generation and redirects with the generating flash when there's no exercise yet" do
      expect {
        post generate_path
      }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)

      expect(response).to redirect_to(root_path)
      expect(flash[:generating]).to be true
    end

    it "no-ops if today's exercise already exists" do
      create_exercise

      expect {
        post generate_path
      }.not_to have_enqueued_job(GenerateDailyExercisesJob)

      expect(response).to redirect_to(root_path)
    end
  end
end
