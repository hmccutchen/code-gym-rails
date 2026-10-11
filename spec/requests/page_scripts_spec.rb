require "rails_helper"

RSpec.describe "Page scripts", type: :request do
  let(:user) { create_user_with_key }

  def doc
    Nokogiri::HTML(response.body)
  end

  before do
    login_as(user)
    get account_path
  end

  it "renders the modules' text onto the body, which a module cannot translate for itself" do
    body = doc.at_css("body")

    expect(body["data-signed-out-text"]).to eq(I18n.t("request.signed_out"))
    expect(body["data-save-failed-text"]).to eq(I18n.t("save_status.generic"))
  end

  it "renders that text for a signed-out visitor too, since the session-expired sentence is what a stale page shows" do
    reset!
    get login_path
    body = doc.at_css("body")

    expect(body["data-signed-out-text"]).to eq(I18n.t("request.signed_out"))
    expect(body["data-save-failed-text"]).to eq(I18n.t("save_status.generic"))
  end

  it "loads the shared modules through importmap" do
    importmap = JSON.parse(doc.at_css('script[type="importmap"]').text)

    expect(importmap["imports"]).to include("application", "code_gym/request", "code_gym/save_status")
    expect(doc.at_css('script[type="module"]')).to be_present
  end

  # Turbo would take over navigation and form submission, which no page here expects.
  it "pins no Turbo" do
    importmap = JSON.parse(doc.at_css('script[type="importmap"]').text)

    expect(importmap["imports"].keys.grep(/turbo/)).to be_empty
  end

  it "defines no page script inline in the head" do
    expect(doc.css("head script").map { |tag| tag["src"] || tag["type"] }).to all(be_present)
  end

  it "starts the generating poll from a controller the module registers, not from inline script" do
    travel_to(Date.new(2026, 7, 13)) do
      get root_path
      page = Nokogiri::HTML(response.body)

      poller = page.at_css("[data-controller~='generating']")
      expect(poller["data-generating-url-value"]).to eq(dashboard_status_path)
      expect(page.css("script:not([src]):not([type])").to_s).not_to include(dashboard_status_path)
    end
  end
end
