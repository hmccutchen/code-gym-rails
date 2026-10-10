require "rails_helper"

# Outside a preview the callback is absent from the chain, and the suite boots without PREVIEW_APP.
RSpec.describe "Preview auto-login", type: :request do
  # Only a row PreviewSeed.seeded? recognizes gets signed in, so sign-in examples need a seeded row.
  def seeded_user(email = PreviewSeed::DEFAULT_EMAIL)
    User.create!(email: email, name: "Preview Reviewer",
                 provider: "anthropic", api_keys: { "anthropic" => PreviewSeed::DUMMY_API_KEY })
  end

  describe "in a non-preview environment (the default)" do
    it "does not register the callback at all" do
      names = ApplicationController._process_action_callbacks.map(&:filter)

      expect(names).not_to include(:preview_auto_login)
      expect(names).not_to include(:remember_preview_sign_out)
    end

    it "leaves an unauthenticated request at the login page" do
      get root_path

      expect(response).to redirect_to(login_path)
    end
  end

  # The suite boots once, so the enabled branch runs by including the concern into a throwaway controller.
  describe "the registration decision" do
    def callbacks_for(controller_class)
      controller_class._process_action_callbacks.map(&:filter)
    end

    def controller_including_the_concern
      Class.new(ActionController::Base) { include PreviewAutoLogin }
    end

    it "registers both callbacks in a preview app" do
      ENV[PreviewEnvironment::VAR] = "1"

      names = callbacks_for(controller_including_the_concern)

      expect(names).to include(:preview_auto_login, :remember_preview_sign_out)
    ensure
      ENV.delete(PreviewEnvironment::VAR)
    end

    it "registers neither outside one" do
      names = callbacks_for(controller_including_the_concern)

      expect(names).not_to include(:preview_auto_login)
      expect(names).not_to include(:remember_preview_sign_out)
    end

    # Prepended so it runs before require_login; re-including into an ApplicationController subclass is a no-op.
    it "runs the sign-in before a require_login declared ahead of it" do
      ENV[PreviewEnvironment::VAR] = "1"
      klass = Class.new(ActionController::Base) do
        before_action :require_login
        include PreviewAutoLogin
      end

      names = callbacks_for(klass)

      expect(names.index(:preview_auto_login)).to be < names.index(:require_login)
    ensure
      ENV.delete(PreviewEnvironment::VAR)
    end
  end

  # Registration is decided at class definition, so behavior is exercised against the method directly.
  describe "the callback's behavior" do
    let(:controller) { ApplicationController.new }
    let(:session)    { {} }
    let(:cookies)    { {} }

    before do
      allow(controller).to receive(:session).and_return(session)
      allow(controller).to receive(:cookies).and_return(cookies)
      allow(controller).to receive(:controller_name).and_return("dashboard")
      controller.extend(PreviewAutoLogin::Behavior)
    end

    it "signs in the seeded preview user" do
      user = seeded_user

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to eq(user.id)
    end

    it "prefers the configured preview address when one is set" do
      user = seeded_user("reviewer@example.com")
      ENV[PreviewSeed::EMAIL_VAR] = "reviewer@example.com"

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to eq(user.id)
    ensure
      ENV.delete(PreviewSeed::EMAIL_VAR)
    end

    # A preview convenience must never turn a missing row into a 500.
    it "declines silently when the seeded user does not exist" do
      expect { controller.send(:preview_auto_login) }.not_to raise_error
      expect(session).to be_empty
    end

    # PreviewSeed leaves a real account at this address untouched, so auto-login must decline on it.
    it "declines for a real account that happens to sit at the configured address" do
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Real Person",
                   provider: "anthropic", api_keys: { "anthropic" => "sk-ant-a-real-key" })

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    it "declines for an account carrying no API key at all" do
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Signed Up, No Key")

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    it "declines for an anonymized user, which User.active excludes" do
      seeded_user.anonymize!

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    it "declines when the signed-out cookie is present" do
      seeded_user
      cookies[PreviewAutoLogin::SIGNED_OUT_COOKIE] = "1"

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    # Signing in mid-login would change real code login, which must stay testable on preview apps.
    it "declines inside SessionsController so code login still works" do
      seeded_user
      allow(controller).to receive(:controller_name).and_return("sessions")

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    it "already logged in is left alone" do
      seeded_user
      real_user = User.create!(email: "already-logged-in@example.com", name: "Real")
      session[:user_id] = real_user.id

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to eq(real_user.id)
    end

    # current_user does not memoize nil, so a session id pointing at no user must not block auto-login.
    it "does not block auto-login when the session id points at no user" do
      user = seeded_user
      session[:user_id] = user.id + 1_000_000

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to eq(user.id)
    end
  end

  describe "remembering a deliberate sign-out" do
    let(:controller) { ApplicationController.new }
    let(:session)    { {} }
    let(:cookies)    { {} }

    before do
      allow(controller).to receive(:session).and_return(session)
      allow(controller).to receive(:cookies).and_return(cookies)
      controller.extend(PreviewAutoLogin::Behavior)
    end

    it "sets the signed-out cookie on sessions#destroy" do
      allow(controller).to receive_messages(controller_name: "sessions", action_name: "destroy")

      controller.send(:remember_preview_sign_out)

      expect(cookies[PreviewAutoLogin::SIGNED_OUT_COOKIE][:value]).to eq("1")
    end

    it "sets the signed-out cookie on accounts#destroy" do
      allow(controller).to receive_messages(controller_name: "accounts", action_name: "destroy")

      controller.send(:remember_preview_sign_out)

      expect(cookies[PreviewAutoLogin::SIGNED_OUT_COOKIE][:value]).to eq("1")
    end

    it "does not set the cookie for a non-destroy action" do
      allow(controller).to receive_messages(controller_name: "sessions", action_name: "create")

      controller.send(:remember_preview_sign_out)

      expect(cookies[PreviewAutoLogin::SIGNED_OUT_COOKIE]).to be_nil
    end

    it "does not set the cookie for destroy on an unrelated controller" do
      allow(controller).to receive_messages(controller_name: "dashboard", action_name: "destroy")

      controller.send(:remember_preview_sign_out)

      expect(cookies[PreviewAutoLogin::SIGNED_OUT_COOKIE]).to be_nil
    end

    it "closes the loop: the cookie it writes is one preview_auto_login declines on" do
      seeded_user
      allow(controller).to receive_messages(controller_name: "sessions", action_name: "destroy")
      controller.send(:remember_preview_sign_out)

      allow(controller).to receive(:controller_name).and_return("dashboard")
      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end
  end
end
