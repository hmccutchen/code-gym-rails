require "rails_helper"

RSpec.describe "Setup Daily sections control", type: :request do
  let(:user) { create_user_with_key }

  def page_html = Nokogiri::HTML(response.body)

  def fixed_section_names
    ExerciseSection.fixed.map { |kind| I18n.t("sections.#{kind.key}.name") }
  end

  it "offers Automatic and every count with the stored one checked" do
    user.update!(daily_section_count: 3)
    login_as(user)

    get setup_path

    radios = page_html.css("#daily-sections input[type=radio]")
    expect(radios.map { |radio| radio["value"] })
      .to eq([ User::AUTOMATIC_SECTION_COUNT, *User::DAILY_SECTION_COUNTS.map(&:to_s) ])
    expect(page_html.at_css("#daily-sections input[checked]")["value"]).to eq("3")
  end

  # The hint holds only while the lowest choice equals the number of fixed sections.
  it "names the fixed sections as everything the lowest choice holds" do
    expect(User::DAILY_SECTION_COUNTS.first).to eq(ExerciseSection.fixed.size)
    login_as(user)

    get setup_path

    hint = page_html.at_css("#daily-sections .hint").text
    expect(hint).to include("#{User::DAILY_SECTION_COUNTS.first} gives you only #{fixed_section_names.to_sentence}")
    expect(hint).not_to include("every day")
  end

  it "says Automatic grows the day only once reviewed answers go well" do
    login_as(user)

    get setup_path

    hint = page_html.at_css("#daily-sections .hint").text
    expect(hint).to include("Automatic gives you shorter sets after days you don't finish, " \
                            "and longer ones once you finish more and your reviewed answers go well.")
  end
end
