require "rails_helper"

RSpec.describe PreviewMail do
  # apply! mutates global job configuration, so restore it or the rest of the
  # suite inherits an inline mail adapter.
  around do |example|
    original = ActionMailer::MailDeliveryJob.queue_adapter
    example.run
    ActionMailer::MailDeliveryJob.queue_adapter = original
  end

  after { ENV.delete(PreviewEnvironment::VAR) }

  it "does nothing outside a preview app" do
    before_adapter = ActionMailer::MailDeliveryJob.queue_adapter

    expect(PreviewMail.apply!).to be(false)
    expect(ActionMailer::MailDeliveryJob.queue_adapter).to eq(before_adapter)
  end

  it "does nothing when the preview flag is blank" do
    ENV[PreviewEnvironment::VAR] = "   "
    before_adapter = ActionMailer::MailDeliveryJob.queue_adapter

    expect(PreviewMail.apply!).to be(false)
    expect(ActionMailer::MailDeliveryJob.queue_adapter).to eq(before_adapter)
  end

  it "sends mail inline in a preview app" do
    ENV[PreviewEnvironment::VAR] = "1"

    expect(PreviewMail.apply!).to be(true)
    expect(ActionMailer::MailDeliveryJob.queue_adapter).to be_a(ActiveJob::QueueAdapters::InlineAdapter)
  end

  it "leaves every other job class on the configured adapter" do
    ENV[PreviewEnvironment::VAR] = "1"
    other_before = GenerateDailyExercisesJob.queue_adapter

    PreviewMail.apply!

    expect(GenerateDailyExercisesJob.queue_adapter).to eq(other_before)
    expect(GenerateDailyExercisesJob.queue_adapter.class.name).not_to match(/Inline/)
  end
end
