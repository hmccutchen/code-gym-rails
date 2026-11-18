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

  it "is exactly as before learner notes while the switch is unset" do
    stub_env("LEARNER_NOTES" => nil)
    get privacy_path
    paragraphs = page.css("section[aria-labelledby='privacy-stored'] p").map(&:text)

    expect(paragraphs).to eq([ I18n.t("privacy.show.stored.body"), I18n.t("privacy.show.stored.kept"),
                               I18n.t("privacy.show.stored.retention", duck_days: DuckThread::KEPT_FOR.in_days.to_i),
                               I18n.t("privacy.show.stored.authenticator") ])
    expect(page.at_css("main").text).not_to match(/learner notes|notes and explanations|short reminders/i)
  end

  it "states what learner notes store, what reads them and how long they are kept, with the numbers from the code" do
    stub_env("LEARNER_NOTES" => "1")
    get privacy_path
    text = page.at_css("main").text

    expect(PrivacyNotice.facts).to include(note_days: LearnerNote::KEPT_FOR.in_days.to_i,
                                           item_days: LearnerItem::KEPT_AFTER_CLOSE.in_days.to_i,
                                           item_lookback_days: LearnerItem::RECENT_DAYS, open_items: LearnerItem::MAX_OPEN)
    expect(text).to include(
      "If you turn on learner notes in Account, the note you write with each set and your answer to the explain " \
      "question are stored. After you submit, one request sent with your key reads them, along with your " \
      "thinking-partner conversation and your answers for that day and your reminders from the last " \
      "#{LearnerItem::RECENT_DAYS} days, and keeps up to #{LearnerItem::MAX_OPEN} short reminders of what to practise next. " \
      "You can read and delete all of them on your Account page. Notes are deleted automatically after " \
      "#{LearnerNote::KEPT_FOR.in_days.to_i} days, reminders #{LearnerItem::KEPT_AFTER_CLOSE.in_days.to_i} days after they " \
      "close, and everything is deleted with your account."
    )
    expect(text).to include("When you save an explanation, a second short request sent with your key reads only that " \
                            "explanation and the question it answered, and stores a brief reply under it, which is " \
                            "deleted with the explanation.")
    expect(text).to include(I18n.t("privacy.show.stored.body_with_learner_notes"))
    expect(I18n.t("privacy.show.stored.body_with_learner_notes"))
      .to include("the notes and explanations you write with each set, the short feedback on each explanation, and the " \
                  "reminders written from them, which later requests sent with your key also read")
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

  it "names concept write-ups and guides as stored, written with the key and removed by deletion" do
    get privacy_path
    text = page.at_css("main").text

    %w[stored.body stored.body_with_learner_notes key.use deleting.body].each do |key|
      expect(I18n.t("privacy.show.#{key}")).to include("write-ups and guides")
    end
    expect(text).not_to match(/stay on Learn for everyone/i)
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
