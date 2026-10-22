require "rails_helper"
require "devise_two_factor/spec_helpers"

RSpec.describe SignInCredentials, type: :model do
  subject { User.new(email: "shared@example.com", name: "Shared") }

  it_behaves_like "two_factor_authenticatable"
  it_behaves_like "two_factor_backupable"

  let(:password) { AuthHelpers::SPEC_PASSWORD }

  describe "who has to confirm an address" do
    it "is only an account created through sign-up, until it confirms" do
      registrant = User.new(email: "new@example.com", name: "New", password: password)
      registrant.signing_up = true
      registrant.save!

      expect(registrant).not_to be_active_for_authentication
      expect(User.find(registrant.id)).not_to be_active_for_authentication

      registrant.confirm
      expect(User.find(registrant.id)).to be_active_for_authentication
    end

    it "is not an account created any other way, which gets no confirmation email" do
      expect { User.create!(email: "seeded@example.com", name: "Seeded") }
        .not_to change(ActionMailer::Base.deliveries, :count)

      expect(User.find_by!(email: "seeded@example.com")).to be_active_for_authentication
    end
  end

  it "refuses an anonymized account" do
    user = create_user_with_key
    user.anonymize!

    expect(user.reload).not_to be_active_for_authentication
  end

  describe ".awaiting_password" do
    it "holds active accounts with no password, the ones the emailed code still serves" do
      waiting = User.create!(email: "waiting@example.com", name: "Waiting")
      User.create!(email: "set@example.com", name: "Set", password: password)
      User.create!(email: "gone@example.com", name: "Gone").anonymize!

      expect(User.awaiting_password).to contain_exactly(waiting)
    end
  end

  describe "enrolling an authenticator" do
    let(:user) { create_user_with_key }

    it "keeps one secret when two setup pages load the account at once" do
      first_tab = User.find(user.id)
      second_tab = User.find(user.id)

      secret = first_tab.prepare_two_factor_secret!

      expect(second_tab.prepare_two_factor_secret!).to eq(secret)
      expect(user.reload.otp_secret).to eq(secret)
    end

    it "keeps one secret until enrollment, so a reload shows the same QR code" do
      secret = user.prepare_two_factor_secret!

      expect(user.reload.prepare_two_factor_secret!).to eq(secret)
    end

    it "turns the authenticator on for a current code and returns ten fresh backup codes" do
      user.prepare_two_factor_secret!

      outcome = user.enroll_two_factor!(user.current_otp)
      codes = outcome.backup_codes

      expect(outcome.status).to eq(:enrolled)
      expect(codes.size).to eq(SignInCredentials::BACKUP_CODE_COUNT)
      expect(user.reload).to be_two_factor_enrolled
      expect(user.invalidate_otp_backup_code!(codes.first)).to be(true)
    end

    it "refuses a second enrollment, even with a fresh code, so the backup codes already shown stay valid" do
      user.prepare_two_factor_secret!
      codes = user.enroll_two_factor!(user.current_otp).backup_codes

      travel(31.seconds) do
        expect(user.enroll_two_factor!(user.current_otp).status).to eq(:already_on)
      end
      expect(user.reload.invalidate_otp_backup_code!(codes.first)).to be(true)
    end

    it "is rejected and stays off for a wrong code or a missing secret" do
      expect(user.enroll_two_factor!("123456").status).to eq(:rejected)

      user.prepare_two_factor_secret!
      expect(user.enroll_two_factor!(wrong_code_for(user.current_otp)).status).to eq(:rejected)
      expect(user.reload).not_to be_two_factor_enrolled
    end
  end

  describe "moving to a new phone" do
    let(:user) { enroll_two_factor(create_user_with_key) }

    it "turns the authenticator off for a current code or a backup code, so setup shows a new secret" do
      backup_code = user.generate_otp_backup_codes!.first
      user.save!

      expect(user.release_authenticator!(backup_code).status).to eq(:released)
      expect(user.reload).to have_attributes(two_factor_enrolled?: false, otp_secret: nil, otp_backup_codes: nil)
    end

    it "is rejected for a wrong code, leaving the authenticator on" do
      expect(user.release_authenticator!(wrong_code_for(user.current_otp)).status).to eq(:rejected)
      expect(user.reload).to be_two_factor_enrolled
    end
  end

  it "clears every sign-in credential when the account is deleted" do
    user = enroll_two_factor(create_user_with_key)
    user.generate_otp_backup_codes!
    user.save!

    user.anonymize!

    expect(user.reload).to have_attributes(encrypted_password: "", otp_secret: nil, two_factor_enrolled?: false,
                                           otp_backup_codes: nil, login_code_digest: nil)
  end
end
