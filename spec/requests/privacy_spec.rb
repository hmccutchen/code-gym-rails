require "rails_helper"

RSpec.describe "Privacy page", type: :request do
  def page = Nokogiri::HTML(response.body)

  def privacy_links = page.css("a[href='#{privacy_path}']")

  it "is open to someone signed out" do
    get privacy_path

    expect(response).to have_http_status(:ok)
    expect(page.at_css("h1").text).to eq(I18n.t("privacy.show.heading"))
    expect(page.at_css("title").text).to eq("#{I18n.t("privacy.show.heading")} – Coding Gym")
  end

  it "offers someone signed out the way to log in" do
    get privacy_path

    expect(page.css("a[href='#{login_path}']")).to be_present
  end

  it "is open to someone signed in with no key yet, without sending them to Setup" do
    login_as(User.create!(email: "new@example.com"))
    get privacy_path

    expect(response).to have_http_status(:ok)
  end

  it "shows a signed-in visitor the nav instead of the log in link" do
    login_as(create_user_with_key)
    get privacy_path

    expect(response).to have_http_status(:ok)
    expect(page.at_css("nav")).to be_present
    expect(page.css("main a[href='#{login_path}']")).to be_empty
  end

  it "fills in the retention numbers from the code that sets them" do
    get privacy_path
    text = page.at_css("main").text

    expect(text).to include(I18n.t("privacy.show.stored.retention", duck_days: DuckThread::KEPT_FOR.in_days.to_i))
    expect(text).to include(I18n.t("privacy.show.cost.pause", count: UnopenedSets::PAUSE_AFTER))
    expect(text).to include(I18n.t("privacy.show.device.body", days: PrivacyNotice.session_days))
    expect(text).to include("kept for up to #{PrivacyNotice::LOG_DAYS} days")
    expect(text).not_to include("%{")
  end

  it "makes no claim about database backups, which are off" do
    get privacy_path

    expect(page.at_css("main").text).not_to match(/backup/i)
  end

  it "speaks for the app, with no first person, no channel to message and no Gemini aside" do
    get privacy_path
    text = page.at_css("main").text.gsub(I18n.t("accounts.show.delete"), "")

    expect(text).not_to match(/\b(I|me|my|I'd|I'm)\b/)
    expect(text).not_to include("Gemini")
    expect(text).not_to include("channel")
  end

  it "says the Account page prices only Anthropic keys and counts requests for the others" do
    get privacy_path

    expect(page.at_css("main").text).to include("an estimate of this month's spend for Anthropic keys, and a request count for the others")
  end

  it "is linked from the login page" do
    get login_path

    expect(privacy_links.map(&:text)).to eq([ I18n.t("sessions.new.privacy_link") ])
  end

  it "is linked from the Account page's delete section" do
    login_as(create_user_with_key)
    get account_path

    note = page.css(".danger-zone p").find { |paragraph| paragraph.at_css("a[href='#{privacy_path}']") }

    expect(note.css("a").map(&:text)).to eq([ I18n.t("accounts.show.privacy_link") ])
    expect(note.text.squish).to end_with(I18n.t("accounts.show.danger_privacy_html", link: I18n.t("accounts.show.privacy_link")))
  end
end
