require "rails_helper"

RSpec.describe "Setup for single-exercise practice", type: :request do
  let(:user) { create_user_with_key }

  [ nil, *User::DAILY_SECTION_COUNTS ].each do |count|
    it "retires count controls while retaining the stored #{count || 'automatic'} setting" do
      user.update!(daily_section_count: count)
      login_as(user)

      get setup_path

      page = Nokogiri::HTML(response.body)
      expect(page.css("#daily-sections, [name=daily_section_count], [data-controller~=daily-sections]")).to be_empty
      expect(page.at_css("#exercise-mix").text).to include("Each new session starts with one exercise.")
      expect(page.css(".mix-unplaced-note")).to be_empty
      expect(page.at_css("#exercise-mix").text).not_to include("not in your sets at this setting")
      expect(user.reload.daily_section_count).to eq(count)
    end
  end

  it "keeps saved difficulty, frequency and exclusion controls available" do
    user.update!(daily_section_count: 1, section_kind_weights: { "challenge" => 2.0 },
      excluded_section_kinds: [ "architecture" ], section_kind_levels: { "challenge" => "senior" },
      locked_section_kinds: [ "challenge" ])
    login_as(user)

    get setup_path

    page = Nokogiri::HTML(response.body)
    expect(page.at_css("#weight-challenge")["value"]).to eq(KindPreferences::MULTIPLIERS.index(2.0).to_s)
    expect(page.at_css("#exclude-architecture")["checked"]).to be_present
    expect(page.at_css("input[name='level-challenge'][value=senior]")["checked"]).to be_present
    expect(page.at_css("#lock-challenge")["checked"]).to be_present
  end
end
