require "rails_helper"

RSpec.describe SecondFactor, type: :model do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
  let(:step_start) { Time.zone.at(1_800_000_000) }

  around { |example| travel_to(step_start + 10.seconds) { example.run } }

  def code_at(secret, offset_steps)
    current_totp(secret, at: Time.current + (offset_steps * User::TOTP_INTERVAL).seconds)
  end

  def wrong_totp(secret)
    valid = (-1..1).map { |offset| code_at(secret, offset) }
    (0..3).map { |n| format("%06d", n) }.find { |candidate| valid.exclude?(candidate) }
  end

  def fail_daily_cap(user, secret)
    User::SECOND_FACTOR_DAILY_FAILURES.times { user.verify_second_factor!(wrong_totp(secret)) }
  end

  describe ".new_second_factor_secret" do
    it "makes a fresh 160-bit secret each time" do
      secret = User.new_second_factor_secret

      expect(ROTP::Base32.decode(secret).bytesize).to eq(20)
      expect(User.new_second_factor_secret).not_to eq(secret)
    end
  end

  describe "#enable_second_factor!" do
    let(:secret) { User.new_second_factor_secret }

    it "needs a valid code for the setup page's secret, and stores nothing until one verifies" do
      expect(user.enable_second_factor!(wrong_totp(secret), secret: secret).status).to eq(:rejected)
      expect(user.enable_second_factor!(code_at(secret, 0), secret: nil).status).to eq(:rejected)
      expect(user.reload.two_factor_enabled?).to be(false)
      expect(user.otp_secret).to be_nil
    end

    it "turns it on, returns ten recovery codes and ends earlier sessions at the same time" do
      outcome = user.enable_second_factor!(code_at(secret, 0), secret: secret)

      expect(outcome.status).to eq(:enabled)
      expect(outcome.recovery_codes.size).to eq(User::RECOVERY_CODE_COUNT)
      expect(outcome.recovery_codes).to all(match(/\A[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}\z/))
      user.reload
      expect(user.two_factor_enabled_at).to eq(outcome.changed_at)
      expect(user.sessions_valid_after).to eq(outcome.changed_at)
      expect(user.otp_secret).to eq(secret)
    end

    it "refuses a second call without making new codes" do
      secret, _codes = enroll_second_factor(user)
      digests = user.reload.otp_backup_codes

      expect(user.enable_second_factor!(code_at(secret, 0), secret: User.new_second_factor_secret).status).to eq(:already_on)
      expect(user.reload.otp_backup_codes).to eq(digests)
    end

    it "refuses a code when the session holds no setup secret" do
      expect(user.enable_second_factor!("123456", secret: nil).status).to eq(:rejected)
    end
  end

  describe "#verify_second_factor!" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }
    let(:recovery_codes) { enrollment.last }

    it "accepts the current step's code" do
      expect(user.verify_second_factor!(code_at(secret, 0)).status).to eq(:totp)
    end

    it "accepts the next step's code" do
      expect(user.verify_second_factor!(code_at(secret, 1)).status).to eq(:totp)
    end

    it "accepts the previous step's code when it is newer than the last one used" do
      travel 30.seconds

      expect(user.verify_second_factor!(code_at(secret, -1)).status).to eq(:totp)
    end

    it "refuses a code two steps away" do
      expect(user.verify_second_factor!(code_at(secret, 2)).status).to eq(:rejected)
      travel 90.seconds
      expect(user.verify_second_factor!(code_at(secret, -2)).status).to eq(:rejected)
    end

    it "refuses the same code a second time" do
      code = code_at(secret, 0)

      expect(user.verify_second_factor!(code).status).to eq(:totp)
      expect(user.verify_second_factor!(code).status).to eq(:rejected)
    end

    it "accepts each recovery code once, in any case and spacing" do
      code = recovery_codes.first

      outcome = user.verify_second_factor!(" #{code.downcase.tr('-', ' ')} ")

      expect(outcome.status).to eq(:recovery_code)
      expect(outcome.remaining).to eq(User::RECOVERY_CODE_COUNT - 1)
      expect(user.verify_second_factor!(code).status).to eq(:rejected)
    end

    it "stores digests that never equal the codes" do
      stored = user.reload.otp_backup_codes

      expect(stored.size).to eq(User::RECOVERY_CODE_COUNT)
      expect(stored & recovery_codes.map { |code| code.delete("-") }).to be_empty
      expect(stored & recovery_codes).to be_empty
    end

    it "checks a 6-digit input as a TOTP only, with no bcrypt comparison" do
      expect(BCrypt::Password).not_to receive(:new)

      expect(user.verify_second_factor!(wrong_totp(secret)).status).to eq(:rejected)
    end

    it "checks a recovery-shaped input against the digests only" do
      expect(ROTP::TOTP).not_to receive(:new)

      expect(user.verify_second_factor!("ABCDE-FGHJK").status).to eq(:rejected)
    end

    it "lets one of two instances of the same user through with the same code" do
      first = User.find(user.id)
      second = User.find(user.id)
      code = code_at(secret, 0)

      expect([ first.verify_second_factor!(code).status, second.verify_second_factor!(code).status ])
        .to eq(%i[totp rejected])
    end

    it "refuses everything when the authenticator is off" do
      user.update!(two_factor_enabled_at: nil)

      expect(user.verify_second_factor!(code_at(secret, 0)).status).to eq(:rejected)
    end
  end

  describe "the daily cap" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "locks out a correct TOTP and an unused recovery code after 20 failures" do
      fail_daily_cap(user, secret)

      expect(user.verify_second_factor!(code_at(secret, 0)).status).to eq(:locked)
      expect(user.verify_second_factor!(enrollment.last.first).status).to eq(:locked)
    end

    it "counts wrong recovery-shaped input toward the cap" do
      User::SECOND_FACTOR_DAILY_FAILURES.times { user.verify_second_factor!("ABCDE-FGHJK") }

      expect(user.verify_second_factor!(code_at(secret, 0)).status).to eq(:locked)
    end

    it "lets a correct code through 24 hours after the first failure" do
      fail_daily_cap(user, secret)

      travel User::SECOND_FACTOR_FAILURE_WINDOW

      expect(user.verify_second_factor!(code_at(secret, 0)).status).to eq(:totp)
    end

    it "starts a new window with the first failure after the old one ends" do
      fail_daily_cap(user, secret)
      travel User::SECOND_FACTOR_FAILURE_WINDOW

      user.verify_second_factor!(wrong_totp(secret))

      expect(user.reload).to have_attributes(second_factor_failures: 1, second_factor_failures_since: Time.current)
    end

    it "never counts a success" do
      user.verify_second_factor!(code_at(secret, 0))
      user.verify_second_factor!(enrollment.last.first)

      expect(user.reload.second_factor_failures).to eq(0)
    end

    it "is shared by turning the authenticator off and making new codes" do
      fail_daily_cap(user, secret)

      expect(user.disable_second_factor!(code_at(secret, 0)).status).to eq(:locked)
      expect(user.regenerate_recovery_codes!(code_at(secret, 0)).status).to eq(:locked)
      expect(user.reload.two_factor_enabled?).to be(true)
    end
  end

  describe "the sign-in challenge" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }
    let!(:issued_at) { User.session_stamp(user.issue_second_factor_challenge!) }

    it "is open only for the time it was issued, and only for its lifetime" do
      expect(user.second_factor_challenge_open?(issued_at)).to be(true)
      expect(user.second_factor_challenge_open?(User.session_stamp(1.second.ago))).to be(false)
      expect(user.second_factor_challenge_open?("not a time")).to be(false)
      travel User::SECOND_FACTOR_CHALLENGE_LIFETIME
      expect(user.second_factor_challenge_open?(issued_at)).to be(false)
    end

    it "yields an accepted outcome inside the row lock, and nothing for a wrong code" do
      in_transaction = nil
      expect { |block| user.answer_second_factor_challenge!(wrong_totp(secret), issued_at: issued_at, &block) }.not_to yield_control

      user.answer_second_factor_challenge!(code_at(secret, 0), issued_at: issued_at) { in_transaction = User.connection.transaction_open? }

      expect(in_transaction).to be(true)
    end

    it "closes once a code is accepted" do
      expect(user.answer_second_factor_challenge!(code_at(secret, 0), issued_at: issued_at).status).to eq(:totp)
      expect(user.reload.second_factor_challenge_at).to be_nil
    end

    it "closes after five wrong codes and counts each toward the daily cap" do
      statuses = Array.new(5) { user.answer_second_factor_challenge!(wrong_totp(secret), issued_at: issued_at).status }

      expect(statuses).to eq(%i[rejected rejected rejected rejected challenge_ended])
      expect(user.reload).to have_attributes(second_factor_challenge_at: nil, second_factor_failures: 5)
    end

    it "refuses a right code once the challenge is closed" do
      user.update!(second_factor_challenge_at: nil)

      expect(user.answer_second_factor_challenge!(code_at(secret, 0), issued_at: issued_at).status).to eq(:expired)
    end

    it "closes when the daily cap is reached and says when to try again" do
      user.update!(second_factor_failures: User::SECOND_FACTOR_DAILY_FAILURES, second_factor_failures_since: 1.hour.ago)

      outcome = user.answer_second_factor_challenge!(code_at(secret, 0), issued_at: issued_at)

      expect(outcome.status).to eq(:locked)
      expect(outcome.retry_at).to eq(user.second_factor_failures_since + User::SECOND_FACTOR_FAILURE_WINDOW)
      expect(user.reload.second_factor_challenge_at).to be_nil
    end
  end

  describe "#regenerate_recovery_codes!" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "replaces the codes and leaves sessions_valid_after alone" do
      valid_after = user.reload.sessions_valid_after

      outcome = user.regenerate_recovery_codes!(code_at(secret, 0))

      expect(outcome.status).to eq(:regenerated)
      expect(outcome.recovery_codes.size).to eq(User::RECOVERY_CODE_COUNT)
      expect(user.reload.sessions_valid_after).to eq(valid_after)
      travel 30.seconds
      expect(user.verify_second_factor!(enrollment.last.second).status).to eq(:rejected)
      expect(user.verify_second_factor!(outcome.recovery_codes.first).status).to eq(:recovery_code)
    end

    it "needs a code" do
      expect(user.regenerate_recovery_codes!(wrong_totp(secret)).status).to eq(:rejected)
    end
  end

  describe "#disable_second_factor!" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "clears all four columns and ends earlier sessions" do
      travel 1.minute

      outcome = user.disable_second_factor!(enrollment.last.first)

      expect(outcome.status).to eq(:disabled)
      expect(user.reload).to have_attributes(otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil,
                                             two_factor_enabled_at: nil, sessions_valid_after: outcome.changed_at)
    end

    it "needs a code" do
      expect(user.disable_second_factor!(wrong_totp(secret)).status).to eq(:rejected)
      expect(user.reload.two_factor_enabled?).to be(true)
    end

    it "reports an authenticator that is already off" do
      user.disable_second_factor!(code_at(secret, 0))

      expect(user.disable_second_factor!(code_at(secret, 1)).status).to eq(:already_off)
    end
  end

  it "stores otp_secret encrypted" do
    secret, _codes = enroll_second_factor(user)

    raw = User.connection.select_value("SELECT otp_secret FROM users WHERE id = #{user.id}")

    expect(raw).to be_present
    expect(raw).not_to include(secret)
  end
end
