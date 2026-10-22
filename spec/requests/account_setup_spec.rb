require "rails_helper"

RSpec.describe "Finishing account setup", type: :request do
  let(:password) { AuthHelpers::SPEC_PASSWORD }

  def sign_in_without_setup(user)
    Warden.on_next_request { |proxy| proxy.set_user(User.find(user.id), scope: :user, event: :authentication) }
  end

  describe "an account with no password" do
    let(:user) { create_user_with_key }

    before { sign_in_without_setup(user) }

    it "is sent to choose a password from every page" do
      get history_path

      expect(response).to redirect_to(edit_password_setup_path)
    end

    it "saves a password, keeps the session and moves on to the authenticator" do
      patch password_setup_path, params: { user: { password: password, password_confirmation: password } }

      expect(response).to redirect_to(two_factor_setup_path)
      expect(user.reload.valid_password?(password)).to be(true)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "refuses a blank, short or mismatched password" do
      [ [ "", "" ], %w[short short], [ password, "#{password}!" ] ].each do |chosen, confirmation|
        patch password_setup_path, params: { user: { password: chosen, password_confirmation: confirmation } }

        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(user.reload).not_to be_password_set
    end
  end

  describe "an account with a password but no authenticator" do
    let(:user) { create_user_with_key.tap { |user| user.update!(password: password) } }

    before { sign_in_without_setup(user) }

    it "is sent to set one up from every page, and cannot reach the password form again" do
      get history_path
      expect(response).to redirect_to(two_factor_setup_path)

      get edit_password_setup_path
      expect(response).to redirect_to(root_path)
    end

    it "shows a QR code and the key it encodes, keeping the same key across visits" do
      get two_factor_setup_path
      secret = user.reload.otp_secret
      get two_factor_setup_path

      expect(response.body).to include("<svg", secret)
      expect(user.reload.otp_secret).to eq(secret)
      expect(user).not_to be_two_factor_enrolled
    end

    it "turns the authenticator on with a current code and shows ten backup codes once" do
      get two_factor_setup_path
      post two_factor_setup_path, params: { code: user.reload.current_otp }

      codes = Nokogiri::HTML(response.body).css(".backup-codes li").map(&:text)
      expect(codes.size).to eq(SignInCredentials::BACKUP_CODE_COUNT)
      expect(user.reload).to be_two_factor_enrolled
      expect(user.otp_backup_codes).not_to include(*codes)

      get two_factor_setup_path
      expect(response).to redirect_to(root_path)
    end

    it "refuses a wrong code and keeps the authenticator off" do
      get two_factor_setup_path
      post two_factor_setup_path, params: { code: wrong_code_for(user.reload.current_otp) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload).not_to be_two_factor_enrolled
    end

    it "limits enrollment attempts" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      get two_factor_setup_path
      10.times { post two_factor_setup_path, params: { code: "000000" } }

      post two_factor_setup_path, params: { code: user.reload.current_otp }

      expect(response).to have_http_status(:too_many_requests)
      expect(user.reload).not_to be_two_factor_enrolled
    end
  end
end
