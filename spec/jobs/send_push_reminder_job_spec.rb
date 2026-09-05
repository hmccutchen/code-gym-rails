require "rails_helper"

RSpec.describe SendPushReminderJob do
  let(:user) do
    User.create!(email: "remind@example.com", name: "Remind", provider: "anthropic",
                 api_key: "sk-ant-test", time_zone: "UTC", push_reminders_enabled: true)
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
    user.update!(push_reminders_enabled: false)
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
end
