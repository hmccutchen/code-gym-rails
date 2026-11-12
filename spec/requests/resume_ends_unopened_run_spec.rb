require "rails_helper"

RSpec.describe "Resuming ends the run of unopened sets", type: :request do
  include ActiveJob::TestHelper

  let(:thursday_morning) { Time.utc(2026, 11, 12, 13, 0) }
  let(:today) { Date.new(2026, 11, 12) }
  let!(:user) { create_user_with_key(email: "back@example.com") }

  def set_on(date, opened_at: nil)
    DailyExercise.create!(user: user, date: date, generated_at: date.in_time_zone("UTC") + 13.hours, opened_at: opened_at,
                          problem_set: { "code_review" => { "question" => "q" } })
  end

  def hand_out(at:) = travel_to(at) { EnqueueDueGenerationsJob.new.perform }

  def scheduled_job = have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id, scheduled: true)

  def paused_by_the_hand_out
    [ today - 3, today - 2, today - 1 ].each { |date| set_on(date) }
    hand_out(at: thursday_morning)
    expect(user.reload).to be_generation_paused_automatically
  end

  resume_paths = {
    "the dashboard line's Resume" => -> { patch toggle_generation_account_path, params: { paused: "0", return_to: "dashboard" } },
    "the Account page's button"   => -> { patch toggle_generation_account_path, params: { paused: "0" } },
    "User#resume_generation!"     => -> { user.reload.resume_generation! }
  }

  resume_paths.each do |name, resume|
    describe "through #{name}" do
      before do
        paused_by_the_hand_out
        travel_to(thursday_morning + 10.minutes) do
          login_as(user)
          instance_exec(&resume)
        end
        clear_enqueued_jobs
      end

      it "leaves the account running at the next hand-out, which enqueues the due user" do
        expect { hand_out(at: thursday_morning + 1.hour) }.to scheduled_job.once

        expect(user.reload.paused_generation_at).to be_nil
      end

      it "does not pause after one new unopened set, or after two" do
        set_on(today)
        expect { hand_out(at: thursday_morning + 1.day) }.to scheduled_job.once
        set_on(today + 1)
        expect { hand_out(at: thursday_morning + 4.days) }.to scheduled_job.once

        expect(user.reload.paused_generation_at).to be_nil
      end

      it "pauses again after three new unopened sets" do
        [ today, today + 1, today + 4 ].each { |date| set_on(date) }

        expect { hand_out(at: thursday_morning + 5.days) }.not_to have_enqueued_job(GenerateDailyExercisesJob)

        expect(user.reload).to be_generation_paused_automatically
      end
    end
  end

  it "does not pause a manually paused account at the first hand-out after it resumes, though its last three sets went unopened" do
    [ today - 3, today - 2, today - 1 ].each { |date| set_on(date) }
    travel_to(thursday_morning - 2.hours) do
      login_as(user)
      patch toggle_generation_account_path, params: { paused: "1" }
      patch toggle_generation_account_path, params: { paused: "0" }
    end
    clear_enqueued_jobs

    expect { hand_out(at: thursday_morning) }.to scheduled_job.once
    expect(user.reload.paused_generation_at).to be_nil
  end

  it "stamps nothing when a stale tab posts Resume to an account that is running, so its run still counts" do
    sets = [ today - 3, today - 2, today - 1 ].map { |date| set_on(date) }
    travel_to(thursday_morning - 1.hour) do
      login_as(user)
      patch toggle_generation_account_path, params: { paused: "0" }
    end

    expect(sets.map { |set| set.reload.opened_at }).to eq([ nil, nil, nil ])
    expect { hand_out(at: thursday_morning) }.not_to have_enqueued_job(GenerateDailyExercisesJob)
    expect(user.reload).to be_generation_paused_automatically
  end

  it "acknowledges nothing when the user chooses Keep it paused" do
    paused_by_the_hand_out
    travel_to(thursday_morning + 10.minutes) do
      login_as(user)
      patch toggle_generation_account_path, params: { paused: "1", return_to: "dashboard" }
    end

    expect(user.daily_exercises.pluck(:opened_at)).to eq([ nil, nil, nil ])
    expect(user.reload.generation_pause_kind).to eq("manual")
  end
end
