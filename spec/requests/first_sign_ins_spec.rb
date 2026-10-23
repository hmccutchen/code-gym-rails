require "rails_helper"

RSpec.describe "First sign-in for an account with no password", type: :request do
  include ActiveJob::TestHelper

  let!(:waiting) { User.create!(email: "dev@example.com", name: "Dev") }

  def signed_in? = session["warden.user.user.key"].present?

  def mailed_code
    ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]
  end

  def request_code(email = waiting.email)
    perform_enqueued_jobs { post first_sign_in_path, params: { email: email } }
  end

  describe "POST /login/first" do
    it "mails a code to an account that has no password yet" do
      expect { post first_sign_in_path, params: { email: "DEV@example.com " } }
        .to have_enqueued_mail(UserMailer, :login_code)

      expect(response).to redirect_to(first_sign_in_path)
      expect(flash[:notice]).to match(/emailed it a 6-digit code/)
    end

    it "creates no account and mails nothing for an unknown address, with the same reply" do
      expect { post first_sign_in_path, params: { email: "new@example.com" } }.not_to change(User, :count)
      expect(enqueued_jobs).to be_empty

      expect(response).to redirect_to(first_sign_in_path)
      expect(flash[:notice]).to match(/emailed it a 6-digit code/)
    end

    it "mails nothing to an account that already has a password" do
      enroll_two_factor(waiting)

      expect { post first_sign_in_path, params: { email: waiting.email } }
        .not_to have_enqueued_mail(UserMailer, :login_code)
    end

    it "mails nothing to an anonymized account" do
      waiting.anonymize!

      expect { post first_sign_in_path, params: { email: "dev@example.com" } }
        .not_to have_enqueued_mail(UserMailer, :login_code)
    end
  end

  describe "the page" do
    it "offers the code form as soon as a code is pending, and keeps the email form below it" do
      post first_sign_in_path, params: { email: waiting.email }
      get first_sign_in_path

      expect(Nokogiri::HTML(response.body).css("input[type=submit]").map { |input| input["value"] })
        .to eq([ "Verify code", "Send code" ])
      expect(response.body).to include(verify_first_sign_in_path)
    end

    it "renders no app nav, since its links only mean anything once signed in" do
      get first_sign_in_path

      expect(Nokogiri::HTML(response.body).at_css("nav")).to be_nil
    end

    it "describes the code field by the error after a wrong code, and marks it invalid" do
      post first_sign_in_path, params: { email: waiting.email }
      follow_redirect!
      post verify_first_sign_in_path, params: { code: wrong_code_for(waiting.generate_login_code!) }

      field = Nokogiri::HTML(response.body).at_css("input[name=code]")
      expect(field["aria-describedby"].split).to eq(%w[flash-alert pending-message])
      expect(field["aria-invalid"]).to eq("true")
    end

    it "drops the pending state once the code it describes has expired" do
      post first_sign_in_path, params: { email: waiting.email }

      travel(User::LOGIN_CODE_EXPIRY + 1.minute) do
        get first_sign_in_path

        expect(response.body).not_to include("pending-message")
      end
    end
  end

  describe "POST /login/first/code" do
    it "signs the account in and sends it to choose a password" do
      request_code

      post verify_first_sign_in_path, params: { code: mailed_code }

      expect(response).to redirect_to(edit_password_setup_path)
      expect(signed_in?).to be(true)
      expect(session[:pending_login_email]).to be_nil
    end

    it "issues a new session on sign-in" do
      request_code
      before_sign_in = session.id.public_id

      post verify_first_sign_in_path, params: { code: mailed_code }
      get edit_password_setup_path

      expect(session.id.public_id).not_to eq(before_sign_in)
    end

    it "rejects a wrong code without signing in" do
      request_code

      post verify_first_sign_in_path, params: { code: wrong_code_for(mailed_code) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(signed_in?).to be(false)
    end

    it "kills the code after five wrong guesses" do
      request_code
      wrong = wrong_code_for(mailed_code)

      5.times { post verify_first_sign_in_path, params: { code: wrong } }

      expect(waiting.reload.login_code_digest).to be_nil
    end

    it "refuses a code once its window has passed" do
      request_code

      travel(User::LOGIN_CODE_EXPIRY + 1.minute) { post verify_first_sign_in_path, params: { code: mailed_code } }

      expect(signed_in?).to be(false)
    end

    it "refuses a code from a browser that did not ask for it" do
      request_code
      other_browser = open_session

      other_browser.post verify_first_sign_in_path, params: { code: mailed_code }

      expect(other_browser.response).to have_http_status(:unprocessable_content)
      expect(other_browser.session["warden.user.user.key"]).to be_nil
    end

    it "refuses a code when a password is set between finding the account and locking it" do
      request_code
      code = mailed_code
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        User.where(id: waiting.id).update_all(encrypted_password: Devise::Encryptor.digest(User, AuthHelpers::SPEC_PASSWORD))
        original.call(*args, &block)
      end

      post verify_first_sign_in_path, params: { code: code }

      expect(signed_in?).to be(false)
    end

    it "starts a trial the account asked for before signing in" do
      stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key")
      invite, invite_code = mint_trial_code
      post start_trial_path, params: { email: waiting.email, invite_code: invite_code, provider: "fake", consent: "1" }
      request_code

      post verify_first_sign_in_path, params: { code: mailed_code }

      expect(waiting.reload).to be_trial
      expect(invite.reload.redeemed_count).to eq(1)
    end

    it "refuses a code issued before the account set a password" do
      request_code
      code = mailed_code
      waiting.update!(password: AuthHelpers::SPEC_PASSWORD)

      post verify_first_sign_in_path, params: { code: code }

      expect(signed_in?).to be(false)
    end
  end
end
