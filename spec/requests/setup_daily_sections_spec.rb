require "rails_helper"

RSpec.describe "Setup Daily sections control", type: :request do
  let(:user) { create_user_with_key }

  def page_html = Nokogiri::HTML(response.body)

  def name(key) = I18n.t("sections.#{key}.name")

  it "offers Automatic and every count from one section up, with the stored one checked" do
    user.update!(daily_section_count: 3)
    login_as(user)

    get setup_path

    radios = page_html.css("#daily-sections .segmented input[type=radio]")
    expect(radios.map { |radio| radio["value"] }).to eq([ User::AUTOMATIC_SECTION_COUNT, "1", "2", "3", "4" ])
    expect(page_html.at_css("#daily-sections .segmented input[checked]")["value"]).to eq("3")
  end

  it "says what 1, 2 and a larger number hold, naming the user's daily sections" do
    user.update!(daily_section_kinds: %w[architecture code_review])
    login_as(user)

    get setup_path

    hint = page_html.css("#daily-sections > .card-note").last.text
    expect(hint).to include("1 gives you one of #{name("architecture")} and #{name("code_review")}, the one you choose, and 2 gives you both.")
    expect(hint).to include("A larger number adds sections you choose, and they appear in every set.")
  end

  it "says Automatic grows the day only once reviewed answers go well" do
    login_as(user)

    get setup_path

    hint = page_html.css("#daily-sections > .card-note").last.text
    expect(hint).to include("Automatic gives you shorter sets after days you don't finish, " \
                            "and longer ones once you finish more and your reviewed answers go well.")
  end

  it "renders a hidden chooser for each count that needs one, and none for Automatic or 2" do
    login_as(user)

    get setup_path

    choosers = page_html.css("#daily-sections [data-daily-sections-target=choice]")
    expect(choosers.map { |chooser| chooser["data-count"] }).to eq(%w[1 3 4])
    expect(choosers).to all(satisfy { |chooser| chooser.key?("hidden") })
  end

  it "asks which daily section a setting of 1 keeps, the first place preselected, each storing its place list" do
    user.update!(daily_section_kinds: %w[design_comparison code_review pattern])
    login_as(user)

    get setup_path

    options = page_html.css("#daily-sections-choice-1 .daily-sections-option")
    expect(options.map { |option| option.text.strip }).to eq([ name("design_comparison"), name("code_review") ])
    expect(options.map { |option| JSON.parse(option.at_css("input")["value"]) })
      .to eq([ %w[design_comparison code_review pattern], %w[code_review design_comparison pattern] ])
    expect(options.first.at_css("input")["checked"]).to be_present
  end

  it "asks for a kind for each extra section, preselecting the stored ones and offering no daily kind" do
    user.update!(daily_section_kinds: %w[code_review design_comparison challenge])
    login_as(user)

    get setup_path

    selects = page_html.css("#daily-sections-choice-4 select")
    expect(selects.map { |select| select.at_css("option[selected]")["value"] }).to eq(%w[challenge pattern])
    expect(selects.first.css("option").map { |option| option["value"] }).not_to include("code_review", "design_comparison")
    expect(page_html.css("#daily-sections-choice-3 select").map { |select| select.at_css("option[selected]")["value"] })
      .to eq(%w[challenge])
    expect(JSON.parse(page_html.at_css("#daily-sections-choice-4")["data-pair"])).to eq(%w[code_review design_comparison])
  end

  it "renders the Exercise mix for the kinds the setting holds, a chosen extra section among those in every set" do
    user.update!(daily_section_count: 3, daily_section_kinds: %w[code_review design_comparison challenge])
    login_as(user)

    get setup_path

    expect(JSON.parse(page_html.at_css("#daily-sections")["data-daily-sections-layout-value"]))
      .to eq(%w[code_review design_comparison challenge])
    expect(page_html.css("#exercise-mix .mix-group").first.css("span[id^=mix-name-]").map(&:text))
      .to eq([ name("code_review"), name("design_comparison"), name("challenge") ])
    expect(page_html.at_css("#weight-challenge")).to be_nil
  end
end
