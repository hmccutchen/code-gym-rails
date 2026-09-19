require "rails_helper"

RSpec.describe SendPushReminderJob do
  let(:user) do
    User.create!(email: "remind@example.com", name: "Remind", provider: "anthropic",
                 api_key: "sk-ant-test", time_zone: "UTC", reminder_level: :ready)
  end

  around do |example|
    ENV["VAPID_PUBLIC_KEY"] = "public"
    ENV["VAPID_PRIVATE_KEY"] = "private"
    example.run
  ensure
    ENV.delete("VAPID_PUBLIC_KEY")
    ENV.delete("VAPID_PRIVATE_KEY")
  end

  def create_exercise(for_user: user, date: Date.current)
    DailyExercise.create!(
      user: for_user, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "question" => "p" }
      }
    )
  end

  def subscribe(for_user: user, endpoint: "https://push.example.com/abc")
    PushSubscription.register!(user: for_user, endpoint: endpoint, p256dh_key: "p", auth_key: "a")
  end

  def answer(exercise, answers, ratings = {})
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: answers, section_ratings: ratings)
  end

  ANSWER = "a genuinely substantive answer here".freeze
  BOTH_ANSWERED = { "code_review" => ANSWER, "pattern" => ANSWER }.freeze
  BOTH_RATED = { "code_review" => "right_level", "pattern" => "right_level" }.freeze

  it "notifies every endpoint the user has registered" do
    create_exercise
    subscribe
    subscribe(endpoint: "https://push.example.com/second")

    expect(PushDelivery).to receive(:deliver).twice.and_return(true)

    described_class.new.perform(user_id: user.id)
  end

  # active_section_keys is the authority for a day's section count; the body
  # must never be built by counting problem_set.keys, which can hold more.
  it "counts the sections the day actually presents" do
    create_exercise
    subscribe

    expect(PushDelivery).to receive(:deliver).with(anything, hash_including(body: "2 sections waiting."))

    described_class.new.perform(user_id: user.id)
  end

  it "does nothing when the user has turned reminders off" do
    user.update!(reminder_level: :none)
    create_exercise
    subscribe

    expect(PushDelivery).not_to receive(:deliver)

    described_class.new.perform(user_id: user.id)
  end

  it "does nothing for an anonymized account" do
    create_exercise
    subscribe
    user.anonymize!

    expect(PushDelivery).not_to receive(:deliver)

    described_class.new.perform(user_id: user.id)
  end

  it "does nothing when the day produced no exercise" do
    subscribe

    expect(PushDelivery).not_to receive(:deliver)

    described_class.new.perform(user_id: user.id)
  end

  # Generation and delivery are separate jobs, so a fast user can finish the set
  # before the reminder about it runs.
  it "does not remind someone who has already submitted" do
    exercise = create_exercise
    subscribe
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "x" * 20 }, submitted_at: Time.current)

    expect(PushDelivery).not_to receive(:deliver)

    described_class.new.perform(user_id: user.id)
  end

  it "does nothing when no VAPID keypair is configured" do
    ENV.delete("VAPID_PUBLIC_KEY")
    create_exercise
    subscribe

    expect(PushDelivery).not_to receive(:deliver)

    described_class.new.perform(user_id: user.id)
  end

  describe "the unfinished-set nudge" do
    it "carries the section count and the hours left in the local day" do
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).to receive(:deliver).with(
        anything, hash_including(title: "Today's set is still waiting",
                                 body:  "2 sections · about 10h left today.")
      ).and_return(true)

      Time.use_zone("UTC") do
        travel_to Time.zone.local(2026, 9, 8, 13, 30) do
          create_exercise
          subscribe

          described_class.new.perform(user_id: user.id, kind: :nudge)
        end
      end
    end

    it "is refused for a user who only opted into the morning push" do
      create_exercise
      subscribe
      user.update!(reminder_level: :ready)

      expect(PushDelivery).not_to receive(:deliver)

      described_class.new.perform(user_id: user.id, kind: :nudge)
    end

    it "still sends the ready push at that level, which is what they asked for" do
      create_exercise
      subscribe
      user.update!(reminder_level: :ready)

      expect(PushDelivery).to receive(:deliver).with(
        anything, hash_including(title: "Today's Code Gym is ready")
      ).and_return(true)

      described_class.new.perform(user_id: user.id)
    end

    # Pins the claim in #hours_left_today's comment that the last nudge always
    # leaves about six hours, which is why no sub-hour branch is written.
    # Widen NUDGE_HOURS past the early evening and this fails, as it should.
    it "leaves at least six hours in the day at its last nudge hour" do
      Time.use_zone("UTC") do
        last = Time.zone.local(2026, 9, 8, PushNudgePlan::NUDGE_HOURS.max, 59, 59)
        expect(last.end_of_day - last).to be >= 6.hours
      end
    end

    # The job runs asynchronously, so every fact the enqueue decided on can have
    # moved by the time it lands. A queue backlog is the realistic case.
    it "sends nothing once the hour has left the nudge window" do
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).not_to receive(:deliver)

      Time.use_zone("UTC") do
        travel_to Time.zone.local(2026, 9, 8, 13, 30) do
          create_exercise
          subscribe
        end

        travel_to Time.zone.local(2026, 9, 8, 22, 15) do
          described_class.new.perform(user_id: user.id, kind: :nudge)
        end
      end
    end

    # The whole point of the feature: a set someone got halfway through and
    # walked away from is what needs reaching, and telling them it is "still
    # waiting" would read as not having noticed the half they did.
    it "names how much is left when the set was only partly answered" do
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).to receive(:deliver).with(
        anything, hash_including(title: "You're partway through today's set",
                                 body:  "1 of 2 sections still to go · about 10h left today.")
      ).and_return(true)

      Time.use_zone("UTC") do
        travel_to Time.zone.local(2026, 9, 8, 11, 0) do
          exercise = create_exercise
          subscribe
          answer(exercise, "code_review" => ANSWER)
        end

        travel_to Time.zone.local(2026, 9, 8, 13, 30) do
          described_class.new.perform(user_id: user.id, kind: :nudge)
        end
      end
    end

    # Answered in full but never submitted is the state closest to done and the
    # one a "still waiting" nudge would describe worst.
    it "asks for the submit once every section is answered and rated" do
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).to receive(:deliver).with(
        anything, hash_including(title: "Today's set is ready to submit",
                                 body:  "All 2 sections answered · about 10h left today.")
      ).and_return(true)

      Time.use_zone("UTC") do
        travel_to Time.zone.local(2026, 9, 8, 11, 0) do
          exercise = create_exercise
          subscribe
          answer(exercise, BOTH_ANSWERED, BOTH_RATED)
        end

        travel_to Time.zone.local(2026, 9, 8, 13, 30) do
          described_class.new.perform(user_id: user.id, kind: :nudge)
        end
      end
    end

    # The dashboard keeps Submit disabled until every answered section is rated,
    # so a fully answered but unrated set must not be told to press it.
    it "names the ratings when they are what is left" do
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).to receive(:deliver).with(
        anything, hash_including(title: "Today's set just needs its difficulty ratings",
                                 body:  "All 2 sections answered · about 10h left today.")
      ).and_return(true)

      Time.use_zone("UTC") do
        travel_to Time.zone.local(2026, 9, 8, 11, 0) do
          exercise = create_exercise
          subscribe
          answer(exercise, BOTH_ANSWERED, "code_review" => "right_level")
        end

        travel_to Time.zone.local(2026, 9, 8, 13, 30) do
          described_class.new.perform(user_id: user.id, kind: :nudge)
        end
      end
    end

    # Without this the hourly tick tells someone mid-answer that they have
    # sections left, which is the nag the stopping rule used to prevent by
    # going silent the moment anything was typed.
    it "holds off while the user is still saving answers" do
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).not_to receive(:deliver)

      Time.use_zone("UTC") do
        travel_to Time.zone.local(2026, 9, 8, 13, 30) do
          exercise = create_exercise
          subscribe
          answer(exercise, "code_review" => ANSWER)

          described_class.new.perform(user_id: user.id, kind: :nudge)
        end
      end
    end

    it "sends nothing for a kind it does not recognise" do
      create_exercise
      subscribe
      user.update!(reminder_level: :ready_and_nudges)

      expect(PushDelivery).not_to receive(:deliver)

      described_class.new.perform(user_id: user.id, kind: :something_else)
    end
  end
end
