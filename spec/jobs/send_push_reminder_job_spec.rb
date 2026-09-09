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
  it "does not nudge someone who has already submitted" do
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

  describe "the unstarted nudge" do
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

    # Pins the assumption that justifies the absent sub-hour branch in
    # #hours_left_today. Widen NUDGE_HOURS and this fails, which is the point.
    it "never reaches its last nudge with less than an hour left in the day" do
      Time.use_zone("UTC") do
        last = Time.zone.local(2026, 9, 8, PushNudgePlan::NUDGE_HOURS.max, 59, 59)
        expect(last.end_of_day - last).to be > 1.hour
      end
    end
  end
end
