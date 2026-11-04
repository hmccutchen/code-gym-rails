require "rails_helper"

RSpec.describe "Page stylesheets", type: :request do
  let(:user) { create_user_with_key }

  before do
    user.update!(language: "ruby_rails", display_preferences: { "theme" => "light" })
    login_as(user)
  end

  def stylesheets
    Nokogiri::HTML(response.body).css("head link[rel=stylesheet]").map { |link| link["href"][%r{/assets/(.+?)-[0-9a-f]+\.css}, 1] }
  end

  def page_sheets = stylesheets.grep(%r{\Apages/})

  { "history" => :history_path, "progress" => :progress_path, "learn" => :learn_path,
    "account" => :account_path, "settings" => :setup_path, "today" => :root_path }.each do |page, path|
    it "links #{page}'s own sheet, after the desktop sheet and before the display sheets" do
      get public_send(path)

      expect(page_sheets).to eq([ "pages/#{page}" ])
      sheet = stylesheets.index("pages/#{page}")
      expect(sheet).to be > stylesheets.index("desktop")
      expect(sheet).to be < stylesheets.index("display")
      expect(sheet).to be < stylesheets.index("display_light")
    end
  end

  def component_sheets = stylesheets.grep(%r{\Acomponents/})

  def expect_component_sheets(*names)
    expect(component_sheets).to eq(names.map { |name| "components/#{name}" })
    expect(page_sheets).to be_empty
    expect(stylesheets.index(component_sheets.first)).to be > stylesheets.index("desktop")
    expect(stylesheets.index(component_sheets.last)).to be < (stylesheets.index("display") || stylesheets.size)
  end

  describe "the authenticator pages, which share the authenticator sheet" do
    def expect_authenticator_sheet_alone = expect_component_sheets("authenticator")

    it "links the form field sheet, then its own, on the setup page, the one with a field" do
      get account_authenticator_path
      expect_component_sheets("form_field", "authenticator")
    end

    it "links its own sheet alone on the sign-in-again page, which has no field" do
      allow(User).to receive(:signed_in_recently?).and_return(false)
      get account_authenticator_path
      expect(response.body).to include(I18n.t("authenticators.sign_in_again.heading"))
      expect_authenticator_sheet_alone
    end

    it "links its own sheet alone on the new recovery codes page, which has no field" do
      secret, = enroll_second_factor(user)
      post login_path, params: { email: user.email }
      post verify_login_code_path, params: { code: user.generate_login_code! }
      post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
      travel User::Authenticator::TOTP_INTERVAL.seconds
      post account_recovery_codes_path, params: { otp_code: current_totp(secret) }
      expect(response.body).to include(I18n.t("recovery_codes.show.heading"))
      expect_authenticator_sheet_alone
    end
  end

  describe "the signed-out sign-in pages, which share the form field and login sheets" do
    before { reset! }

    it "links them on the sign-in page" do
      get login_path
      expect_component_sheets("form_field", "login")
    end

    it "links them on the enter-code page" do
      post login_path, params: { email: user.email }
      get login_code_path
      expect(response.body).to include("6-digit code")
      expect_component_sheets("form_field", "login")
    end

    it "links them on the second-factor page" do
      enroll_second_factor(user)
      post login_path, params: { email: user.email }
      get second_factor_challenge_path
      expect(response).to have_http_status(:ok)
      expect_component_sheets("form_field", "login")
    end
  end

  describe "the trial pages, which share the form field and trial sheets" do
    before { allow(TrialMode).to receive(:providers).and_return(%w[anthropic]) }

    it "links them on the signed-out start page" do
      reset!
      get new_trial_path
      expect_component_sheets("form_field", "trial")
    end

    it "links them on the signed-in trial page" do
      user.update!(api_keys: {}, provider: nil)
      get trial_path
      expect(response).to have_http_status(:ok)
      expect_component_sheets("form_field", "trial")
    end
  end

  it "links no page sheet on a page that has none" do
    [ learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one") ].each do |path|
      get path
      expect(page_sheets).to be_empty, "#{path} links #{page_sheets.inspect}"
    end
  end
end
