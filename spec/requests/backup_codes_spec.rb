require "rails_helper"

RSpec.describe "Making new backup codes", type: :request do
  let(:user) { enroll_two_factor(create_user_with_key) }

  before do
    user.generate_otp_backup_codes!
    user.save!
    login_as(user)
  end

  it "replaces every backup code when given a current authenticator code, and shows the new ones once" do
    old_digests = user.reload.otp_backup_codes

    post backup_codes_path, params: { code: user.current_otp }

    codes = Nokogiri::HTML(response.body).css(".backup-codes li").map(&:text)
    expect(codes.size).to eq(SignInCredentials::BACKUP_CODE_COUNT)
    expect(user.reload.otp_backup_codes).not_to include(*old_digests)
  end

  it "keeps the codes as they were for a wrong code" do
    old_digests = user.reload.otp_backup_codes

    post backup_codes_path, params: { code: wrong_code_for(user.current_otp) }

    expect(response).to redirect_to(account_path)
    expect(user.reload.otp_backup_codes).to eq(old_digests)
  end

  it "offers the form on the Account page" do
    get account_path

    expect(response.body).to include(backup_codes_path, "Make new backup codes")
  end
end
