require "rails_helper"

RSpec.describe User::Authenticator, type: :model do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
  let(:authenticator) { described_class.new(user) }
  let(:step_start) { Time.zone.at(1_800_000_000) }

  around { |example| travel_to(step_start + 10.seconds) { example.run } }

  def code_at(secret, offset_steps)
    current_totp(secret, at: Time.current + (offset_steps * described_class::TOTP_INTERVAL).seconds)
  end

  def wrong_totp(secret)
    valid = (-1..1).map { |offset| code_at(secret, offset) }
    (0..3).map { |n| format("%06d", n) }.find { |candidate| valid.exclude?(candidate) }
  end

  def fail_daily_cap(secret)
    described_class::DAILY_FAILURES.times { authenticator.verify!(wrong_totp(secret)) }
  end

  describe ".new_secret" do
    it "makes a fresh 160-bit secret each time" do
      secret = described_class.new_secret

      expect(ROTP::Base32.decode(secret).bytesize).to eq(20)
      expect(described_class.new_secret).not_to eq(secret)
    end
  end

  describe "#sign_in_factor" do
    it "is the emailed code until the authenticator is on, and the authenticator after" do
      expect(authenticator.sign_in_factor).to eq(:emailed_code)
      expect(authenticator.emailed_code_signs_in?).to be(true)

      enroll_second_factor(user)

      user.reload
      expect(authenticator.sign_in_factor).to eq(:authenticator)
      expect(authenticator.emailed_code_signs_in?).to be(false)
    end
  end

  describe "#enable!" do
    let(:secret) { described_class.new_secret }

    it "needs a valid code for the setup page's secret, and stores nothing until one verifies" do
      expect(authenticator.enable!(wrong_totp(secret), secret: secret).status).to eq(:rejected)
      expect(authenticator.enable!(code_at(secret, 0), secret: nil).status).to eq(:rejected)
      user.reload
      expect(authenticator.enabled?).to be(false)
      expect(user.otp_secret).to be_nil
    end

    it "turns it on, returns ten recovery codes and ends earlier sessions at the same time" do
      outcome = authenticator.enable!(code_at(secret, 0), secret: secret)

      expect(outcome.status).to eq(:enabled)
      expect(outcome.recovery_codes.size).to eq(described_class::RECOVERY_CODE_COUNT)
      expect(outcome.recovery_codes).to all(match(/\A[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}\z/))
      user.reload
      expect(user.two_factor_enabled_at).to eq(outcome.changed_at)
      expect(user.sessions_valid_after).to eq(outcome.changed_at)
      expect(user.otp_secret).to eq(secret)
    end

    it "refuses a second call without making new codes" do
      secret, _codes = enroll_second_factor(user)
      digests = user.reload.otp_backup_codes

      expect(authenticator.enable!(code_at(secret, 0), secret: described_class.new_secret).status).to eq(:already_on)
      expect(user.reload.otp_backup_codes).to eq(digests)
    end

    it "refuses a code when the session holds no setup secret" do
      expect(authenticator.enable!("123456", secret: nil).status).to eq(:rejected)
    end
  end

  describe "#verify!" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }
    let(:recovery_codes) { enrollment.last }

    it "accepts the current step's code" do
      expect(authenticator.verify!(code_at(secret, 0)).status).to eq(:totp)
    end

    it "accepts the next step's code" do
      expect(authenticator.verify!(code_at(secret, 1)).status).to eq(:totp)
    end

    it "accepts the previous step's code when it is newer than the last one used" do
      travel 30.seconds

      expect(authenticator.verify!(code_at(secret, -1)).status).to eq(:totp)
    end

    it "refuses a code two steps away" do
      expect(authenticator.verify!(code_at(secret, 2)).status).to eq(:rejected)
      travel 90.seconds
      expect(authenticator.verify!(code_at(secret, -2)).status).to eq(:rejected)
    end

    it "refuses the same code a second time" do
      code = code_at(secret, 0)

      expect(authenticator.verify!(code).status).to eq(:totp)
      expect(authenticator.verify!(code).status).to eq(:rejected)
    end

    it "accepts each recovery code once, in any case and spacing" do
      code = recovery_codes.first

      outcome = authenticator.verify!(" #{code.downcase.tr('-', ' ')} ")

      expect(outcome.status).to eq(:recovery_code)
      expect(outcome.remaining).to eq(described_class::RECOVERY_CODE_COUNT - 1)
      expect(authenticator.verify!(code).status).to eq(:rejected)
    end

    it "stores digests that never equal the codes" do
      stored = user.reload.otp_backup_codes

      expect(stored.size).to eq(described_class::RECOVERY_CODE_COUNT)
      expect(stored & recovery_codes.map { |code| code.delete("-") }).to be_empty
      expect(stored & recovery_codes).to be_empty
    end

    it "checks a 6-digit input as a TOTP only, with no bcrypt comparison" do
      expect(BCrypt::Password).not_to receive(:new)

      expect(authenticator.verify!(wrong_totp(secret)).status).to eq(:rejected)
    end

    it "checks a recovery-shaped input against the digests only" do
      expect(ROTP::TOTP).not_to receive(:new)

      expect(authenticator.verify!("ABCDE-FGHJK").status).to eq(:rejected)
    end

    it "lets one of two instances of the same user through with the same code" do
      first = User.find(user.id)
      second = User.find(user.id)
      code = code_at(secret, 0)

      expect([ described_class.new(first).verify!(code).status, described_class.new(second).verify!(code).status ])
        .to eq(%i[totp rejected])
    end

    it "refuses everything when the authenticator is off" do
      user.update!(two_factor_enabled_at: nil)

      expect(authenticator.verify!(code_at(secret, 0)).status).to eq(:rejected)
    end
  end

  describe "the daily cap" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "locks out a correct TOTP and an unused recovery code after 20 failures" do
      fail_daily_cap(secret)

      expect(authenticator.verify!(code_at(secret, 0)).status).to eq(:locked)
      expect(authenticator.verify!(enrollment.last.first).status).to eq(:locked)
    end

    it "counts wrong recovery-shaped input toward the cap" do
      described_class::DAILY_FAILURES.times { authenticator.verify!("ABCDE-FGHJK") }

      expect(authenticator.verify!(code_at(secret, 0)).status).to eq(:locked)
    end

    it "lets a correct code through 24 hours after the first failure" do
      fail_daily_cap(secret)

      travel described_class::FAILURE_WINDOW

      expect(authenticator.verify!(code_at(secret, 0)).status).to eq(:totp)
    end

    it "starts a new window with the first failure after the old one ends" do
      fail_daily_cap(secret)
      travel described_class::FAILURE_WINDOW

      authenticator.verify!(wrong_totp(secret))

      expect(user.reload).to have_attributes(second_factor_failures: 1, second_factor_failures_since: Time.current)
    end

    it "never counts a success" do
      authenticator.verify!(code_at(secret, 0))
      authenticator.verify!(enrollment.last.first)

      expect(user.reload.second_factor_failures).to eq(0)
    end

    it "is shared by turning the authenticator off and making new codes" do
      fail_daily_cap(secret)

      expect(authenticator.disable!(code_at(secret, 0)).status).to eq(:locked)
      expect(authenticator.regenerate_recovery_codes!(code_at(secret, 0)).status).to eq(:locked)
      user.reload
      expect(authenticator.enabled?).to be(true)
    end
  end

  describe "the sign-in challenge" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }
    let!(:issued_at) { User.session_stamp(authenticator.issue_challenge!) }

    it "hands back the open challenge, wrong codes kept, when asked again within a double tap" do
      authenticator.answer_challenge!(wrong_totp(secret), issued_at: issued_at)

      travel described_class::DOUBLE_TAP_WINDOW - 1.second
      expect(User.session_stamp(authenticator.issue_challenge!)).to eq(issued_at)

      expect(user.reload.second_factor_challenge_failures).to eq(1)
    end

    it "issues a fresh challenge once a double tap's window has passed" do
      authenticator.answer_challenge!(wrong_totp(secret), issued_at: issued_at)

      travel described_class::DOUBLE_TAP_WINDOW + 1.second
      expect(User.session_stamp(authenticator.issue_challenge!)).not_to eq(issued_at)

      expect(user.reload.second_factor_challenge_failures).to eq(0)
    end

    it "issues a fresh challenge when the last one was ended" do
      described_class::CHALLENGE_FAILURES.times { authenticator.answer_challenge!(wrong_totp(secret), issued_at: issued_at) }

      travel 1.second
      expect(User.session_stamp(authenticator.issue_challenge!)).not_to eq(issued_at)
    end

    it "is open only for the time it was issued, and only for its lifetime" do
      expect(authenticator.challenge_open?(issued_at)).to be(true)
      expect(authenticator.challenge_open?(User.session_stamp(1.second.ago))).to be(false)
      expect(authenticator.challenge_open?("not a time")).to be(false)
      travel described_class::CHALLENGE_LIFETIME
      expect(authenticator.challenge_open?(issued_at)).to be(false)
    end

    it "yields an accepted outcome inside the row lock, and nothing for a wrong code" do
      in_transaction = nil
      expect { |block| authenticator.answer_challenge!(wrong_totp(secret), issued_at: issued_at, &block) }.not_to yield_control

      authenticator.answer_challenge!(code_at(secret, 0), issued_at: issued_at) { in_transaction = User.connection.transaction_open? }

      expect(in_transaction).to be(true)
    end

    it "closes once a code is accepted" do
      expect(authenticator.answer_challenge!(code_at(secret, 0), issued_at: issued_at).status).to eq(:totp)
      expect(user.reload.second_factor_challenge_at).to be_nil
    end

    it "closes after five wrong codes and counts each toward the daily cap" do
      statuses = Array.new(5) { authenticator.answer_challenge!(wrong_totp(secret), issued_at: issued_at).status }

      expect(statuses).to eq(%i[rejected rejected rejected rejected challenge_ended])
      expect(user.reload).to have_attributes(second_factor_challenge_at: nil, second_factor_failures: 5)
    end

    it "refuses a right code once the challenge is closed" do
      user.update!(second_factor_challenge_at: nil)

      expect(authenticator.answer_challenge!(code_at(secret, 0), issued_at: issued_at).status).to eq(:expired)
    end

    it "closes when the daily cap is reached and says when to try again" do
      user.update!(second_factor_failures: described_class::DAILY_FAILURES, second_factor_failures_since: 1.hour.ago)

      outcome = authenticator.answer_challenge!(code_at(secret, 0), issued_at: issued_at)

      expect(outcome.status).to eq(:locked)
      expect(outcome.retry_at).to eq(user.second_factor_failures_since + described_class::FAILURE_WINDOW)
      expect(user.reload.second_factor_challenge_at).to be_nil
    end
  end

  describe "#regenerate_recovery_codes!" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "replaces the codes and leaves sessions_valid_after alone" do
      valid_after = user.reload.sessions_valid_after

      outcome = authenticator.regenerate_recovery_codes!(code_at(secret, 0))

      expect(outcome.status).to eq(:regenerated)
      expect(outcome.recovery_codes.size).to eq(described_class::RECOVERY_CODE_COUNT)
      expect(user.reload.sessions_valid_after).to eq(valid_after)
      travel 30.seconds
      expect(authenticator.verify!(enrollment.last.second).status).to eq(:rejected)
      expect(authenticator.verify!(outcome.recovery_codes.first).status).to eq(:recovery_code)
    end

    it "needs a code" do
      expect(authenticator.regenerate_recovery_codes!(wrong_totp(secret)).status).to eq(:rejected)
    end
  end

  describe "#disable!" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "clears all four columns and ends earlier sessions" do
      travel 1.minute

      outcome = authenticator.disable!(enrollment.last.first)

      expect(outcome.status).to eq(:disabled)
      expect(user.reload).to have_attributes(otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil,
                                             two_factor_enabled_at: nil, sessions_valid_after: outcome.changed_at)
    end

    it "needs a code" do
      expect(authenticator.disable!(wrong_totp(secret)).status).to eq(:rejected)
      user.reload
      expect(authenticator.enabled?).to be(true)
    end

    it "reports an authenticator that is already off" do
      authenticator.disable!(code_at(secret, 0))

      expect(authenticator.disable!(code_at(secret, 1)).status).to eq(:already_off)
    end
  end

  it "stores otp_secret encrypted" do
    secret, _codes = enroll_second_factor(user)

    raw = User.connection.select_value("SELECT otp_secret FROM users WHERE id = #{user.id}")

    expect(raw).to be_present
    expect(raw).not_to include(secret)
  end
end
