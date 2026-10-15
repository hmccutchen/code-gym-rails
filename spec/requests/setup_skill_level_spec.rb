require "rails_helper"

RSpec.describe "Setup skill level control", type: :request do
  let(:user) { create_user_with_key }

  def page_html = Nokogiri::HTML(response.body)

  it "offers every skill level with the stored one selected" do
    user.update!(skill_level: "senior")
    login_as(user)

    get setup_path

    select = page_html.at_css("select#skill-level")
    expect(select.css("option").map { |option| option["value"] }).to eq(User::SKILL_LEVELS)
    expect(select.at_css("option[selected]")["value"]).to eq("senior")
    expect(page_html.at_css("label[for='skill-level']").text).to include("Skill level")
  end

  it "names each level as the Exercise mix's difficulty options do" do
    login_as(user)

    get setup_path

    expect(page_html.css("select#skill-level option").map(&:text)).to eq([ "Junior", "Mid-level", "Senior", "Principal engineer" ])
    expect(page_html.css("select#skill-level option").map(&:text))
      .to eq(User::SKILL_LEVELS.map { |level| I18n.t("exercise_mix.levels.#{level}") })
    expect(page_html.text).to include("Junior suits early-career developers and career changers. Your ratings")
  end

  it "defaults a new account to Junior" do
    expect(User.new.skill_level).to eq("junior")
  end

  it "says what the setting does, that ratings still adjust each set, and that only the user changes it" do
    login_as(user)

    get setup_path

    expect(page_html.text).to include("The level each section uses unless you set one for it in the Exercise mix below.",
                                     "Your ratings nudge each day's set, but this setting changes only when you change it.",
                                     "Code Gym suggests a level for that section, and you decide.")
  end

  it "sits above the Exercise mix, whose default options name it" do
    login_as(user)

    get setup_path

    ids = page_html.css("#skill-level, #exercise-mix").map { |node| node["id"] }
    expect(ids).to eq(%w[skill-level exercise-mix])
    expect(page_html.css("[data-skill-level-label]").map(&:text).uniq).to eq([ "Your skill level (Junior)" ])
  end
end
