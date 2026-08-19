require "rails_helper"

# The security property this feature turns on is that in a non-preview
# environment the callback does not exist in the chain — there is no path that
# declines, because there is no path. The suite boots without PREVIEW_APP, so
# that state is the default here and can be asserted directly.
RSpec.describe "Preview auto-login", type: :request do
  # PreviewSeed.seeded? is what separates the demo account from a real one that
  # happens to sit at the same address, so every example that expects a sign-in
  # needs a row the seeder would have created.
  def seeded_user(email = PreviewSeed::DEFAULT_EMAIL)
    User.create!(email: email, name: "Preview Reviewer",
                 provider: "anthropic", api_key: PreviewSeed::DUMMY_API_KEY)
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

  # The suite cannot boot twice, so the enabled half of the registration
  # decision is exercised by including the concern into a throwaway controller
  # with the gate set — the same `included do` block ApplicationController runs
  # at load. Without this, deleting both `if PreviewEnvironment.active?` lines
  # would leave every other example here passing.
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

    # prepend, not append: ApplicationController declares require_login before
    # this module is included, and a callback appended after it would redirect
    # to the login page before this one ever ran. Asserted on a throwaway class
    # in the same order, since re-including the concern into an
    # ApplicationController subclass is a no-op — the module is already in its
    # ancestors, so the `included` block would not run a second time.
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

    # A preview environment miswired to a shared database, or an EMAIL_VAR
    # naming a real teammate, would otherwise hand every anonymous visitor that
    # person's account. PreviewSeed deliberately leaves such a row untouched
    # (spec/services/preview_seed_spec.rb), so auto-login must decline on it.
    it "declines for a real account that happens to sit at the configured address" do
      User.create!(email: PreviewSeed::DEFAULT_EMAIL, name: "Real Person",
                   provider: "anthropic", api_key: "sk-ant-a-real-key")

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

    # Auto-authenticating someone as they hit the verify URL would change real
    # magic-link behavior, which the constraints forbid — and would make the
    # flow untestable on the one deployment where it is easiest to test.
    it "declines inside SessionsController so magic-link login still works" do
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

    # session[:user_id] can outlive the row it points at (account deletion,
    # a stale cookie from a reseeded database). current_user's ||= does not
    # memoize nil, so the same query a later require_login runs sees the
    # seeded user's id this callback sets rather than getting stuck behind it.
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
