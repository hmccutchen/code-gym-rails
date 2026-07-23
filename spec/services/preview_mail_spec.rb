require "rails_helper"

RSpec.describe PreviewMail do
  # apply! mutates global job configuration, so restore it or the rest of the
  # suite inherits an inline mail adapter.
  around do |example|
    original = ActionMailer::MailDeliveryJob.queue_adapter
    example.run
    ActionMailer::MailDeliveryJob.queue_adapter = original
  end

  after { ENV.delete("PREVIEW_SEED_EMAIL") }

  it "does nothing when PREVIEW_SEED_EMAIL is unset" do
    before_adapter = ActionMailer::MailDeliveryJob.queue_adapter

    expect(PreviewMail.apply!).to be(false)
    expect(ActionMailer::MailDeliveryJob.queue_adapter).to eq(before_adapter)
  end

  it "does nothing when PREVIEW_SEED_EMAIL is blank" do
    ENV["PREVIEW_SEED_EMAIL"] = "   "
    before_adapter = ActionMailer::MailDeliveryJob.queue_adapter

    expect(PreviewMail.apply!).to be(false)
    expect(ActionMailer::MailDeliveryJob.queue_adapter).to eq(before_adapter)
  end

  it "sends mail inline when PREVIEW_SEED_EMAIL is set" do
    ENV["PREVIEW_SEED_EMAIL"] = "reviewer@example.com"

    expect(PreviewMail.apply!).to be(true)
    expect(ActionMailer::MailDeliveryJob.queue_adapter.class.name).to match(/Inline/)
  end

  it "leaves every other job class on the configured adapter" do
    ENV["PREVIEW_SEED_EMAIL"] = "reviewer@example.com"
    other_before = GenerateDailyExercisesJob.queue_adapter

    PreviewMail.apply!

    expect(GenerateDailyExercisesJob.queue_adapter).to eq(other_before)
    expect(GenerateDailyExercisesJob.queue_adapter.class.name).not_to match(/Inline/)
  end
end
