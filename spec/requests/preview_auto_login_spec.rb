require "rails_helper"

# The security property this feature turns on is that in a non-preview
# environment the callback does not exist in the chain — there is no path that
# declines, because there is no path. The suite boots without PREVIEW_APP, so
# that state is the default here and can be asserted directly.
RSpec.describe "Preview auto-login", type: :request do
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

  # The callback's behavior is exercised against the method directly, because
  # registration is decided at class-definition time and the suite cannot boot
  # twice. See the plan's note on this tradeoff.
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
      user = User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to eq(user.id)
    end

    it "prefers the configured preview address when one is set" do
      user = User.create!(email: "reviewer@example.com", name: "R")
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

    it "declines for an anonymized user, which User.active excludes" do
      user = User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")
      user.anonymize!

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    it "declines when the signed-out cookie is present" do
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")
      cookies[PreviewAutoLogin::SIGNED_OUT_COOKIE] = "1"

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    # Auto-authenticating someone as they hit the verify URL would change real
    # magic-link behavior, which the constraints forbid — and would make the
    # flow untestable on the one deployment where it is easiest to test.
    it "declines inside SessionsController so magic-link login still works" do
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")
      allow(controller).to receive(:controller_name).and_return("sessions")

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end

    it "already logged in is left alone" do
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")
      real_user = User.create!(email: "already-logged-in@example.com", name: "Real")
      session[:user_id] = real_user.id

      controller.send(:preview_auto_login)

      expect(session[:user_id]).to eq(real_user.id)
    end

    # session[:user_id] can outlive the row it points at (account deletion,
    # a stale cookie from a reseeded database). current_user's ||= does not
    # memoize nil, so the same query a later require_login runs sees the
    # seeded user's id this callback sets rather than getting stuck behind it.
    it "does not block auto-login when the session id points at no user" do
      user = User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")
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
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Preview Reviewer")
      allow(controller).to receive_messages(controller_name: "sessions", action_name: "destroy")
      controller.send(:remember_preview_sign_out)

      allow(controller).to receive(:controller_name).and_return("dashboard")
      controller.send(:preview_auto_login)

      expect(session[:user_id]).to be_nil
    end
  end
end
