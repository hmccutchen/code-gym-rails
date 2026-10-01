require "rails_helper"

RSpec.describe "Setup skill level control", type: :request do
  let(:user) { create_user_with_key }

  def page_html = Nokogiri::HTML(response.body)

  it "offers every skill level with the stored one selected" do
    user.update!(skill_level: "solid")
    login_as(user)

    get setup_path

    select = page_html.at_css("select#skill-level")
    expect(select.css("option").map { |option| option["value"] }).to eq(User::SKILL_LEVELS)
    expect(select.at_css("option[selected]")["value"]).to eq("solid")
    expect(page_html.at_css("label[for='skill-level']").text).to include("Skill level")
  end

  it "says what the setting does and that ratings still adjust each set" do
    login_as(user)

    get setup_path

    expect(response.body).to include("unless you've set a difficulty for that section in the Exercise mix below",
                                     "Your ratings still nudge each day's set up or down")
  end

  it "sits above the Exercise mix, whose default options name it" do
    login_as(user)

    get setup_path

    ids = page_html.css("#skill-level, #exercise-mix").map { |node| node["id"] }
    expect(ids).to eq(%w[skill-level exercise-mix])
    expect(page_html.css("[data-skill-level-label]").map(&:text).uniq).to eq([ "Your skill level (developing)" ])
  end
end
