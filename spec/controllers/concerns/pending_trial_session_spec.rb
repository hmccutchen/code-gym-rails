require "rails_helper"

RSpec.describe PendingTrialSession do
  include AuthHelpers

  let(:host) do
    Class.new do
      include PendingTrialSession
      public :remember_pending_trial, :forget_pending_trial, :take_pending_trial

      def session = @session ||= {}
    end.new
  end
  let(:invite) { mint_trial_code.first }
  let(:consented_at) { Time.utc(2026, 10, 7, 14) }

  def remember
    host.remember_pending_trial(email: "new@example.com", invite: invite, provider: "fake", consented_at: consented_at)
  end

  it "keeps the pending trial under the session key and shape sessions already hold" do
    remember

    expect(host.session).to eq(pending_trial: { "email" => "new@example.com", "invite_code_id" => invite.id,
                                                "provider" => "fake", "consented_at" => "2026-10-07T14:00:00Z" })
  end

  it "hands the pending trial out once" do
    remember

    expect(host.take_pending_trial).to be_a(PendingTrial)
    expect(host.session).not_to have_key(:pending_trial)
    expect(host.take_pending_trial).to be_nil
  end

  it "takes a pending trial written before the deploy" do
    host.session[:pending_trial] = { "email" => "new@example.com", "invite_code_id" => invite.id,
                                     "provider" => "fake", "consented_at" => "2026-10-07T14:00:00Z" }

    expect(host.take_pending_trial).to be_a(PendingTrial)
  end

  it "drops a value that isn't a pending trial" do
    host.session[:pending_trial] = "garbled"

    expect(host.take_pending_trial).to be_nil
    expect(host.session).not_to have_key(:pending_trial)
  end

  it "forgets the pending trial" do
    remember

    host.forget_pending_trial

    expect(host.session).to be_empty
  end
end
