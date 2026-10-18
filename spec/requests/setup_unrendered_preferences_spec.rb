require "rails_helper"

RSpec.describe "Exercise mix settings Setup does not render", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) { create_fake_provider_user }

  before { login_as(user) }

  def swap(place, kind)
    patch daily_kind_path(place), params: { kind: kind, section_kind_preferences_version: user.reload.section_kind_preferences_version }.to_json,
                                  headers: json
  end

  def save_mix(user_params, layout: DailyKinds.for(user.reload).map(&:key))
    patch profile_path, params: { user: user_params.merge(section_kind_preferences_version: user.reload.section_kind_preferences_version),
                                  layout: layout }.to_json, headers: json
  end

  it "renders weights for exactly the rotatable kinds and difficulty for exactly the pickable kinds" do
    [ [], %w[code_review plan_review], %w[architecture code_review] ].each do |pair|
      user.update!(daily_section_kinds: pair)
      daily = DailyKinds.for(user)

      get setup_path
      page = Nokogiri::HTML(response.body)

      expect(page.css(".mix-row[data-kind]").map { |row| row["data-kind"] })
        .to match_array(ExerciseSection.rotatable(daily: daily).map(&:key)), pair.inspect
      expect(page.css("fieldset.mix-difficulty[data-kind]").map { |box| box["data-kind"] })
        .to match_array(ExerciseSection.pickable(daily: daily).map(&:key)), pair.inspect
    end
  end

  it "keeps a daily fourth's siblings' weight, exclusion, target and lock through an unrelated save and a swap back" do
    siblings = { section_kind_weights: { "ambiguity_hunt" => 2.0 }, excluded_section_kinds: %w[pseudocode_to_code],
                 section_kind_levels: { "ambiguity_hunt" => "senior", "pseudocode_to_code" => "junior" },
                 locked_section_kinds: %w[ambiguity_hunt] }
    user.update!(siblings)

    swap(1, "plan_review")
    expect(response).to have_http_status(:ok)
    save_mix({ section_kind_weights: { "architecture" => 0.5 }, excluded_section_kinds: [],
               section_kind_levels: { "challenge" => "mid_level" }, locked_section_kinds: [] })
    expect(response).to have_http_status(:ok)
    swap(1, "design_comparison")

    user.reload
    expect(user.section_kind_weights).to eq("ambiguity_hunt" => 2.0, "architecture" => 0.5)
    expect(user.excluded_section_kinds).to eq(%w[pseudocode_to_code])
    expect(user.section_kind_levels).to eq("ambiguity_hunt" => "senior", "pseudocode_to_code" => "junior", "challenge" => "mid_level")
    expect(user.locked_section_kinds).to eq(%w[ambiguity_hunt])
  end

  it "tells a stale page whether it was rendered for another pair, so it reloads instead of saving with missing controls" do
    rendered = DailyKinds.for(user).map(&:key)
    stale = user.section_kind_preferences_version
    swap(1, "challenge")

    patch profile_path, params: { user: { section_kind_weights: {}, section_kind_preferences_version: stale },
                                  layout: rendered }.to_json, headers: json
    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body)).to include("layout_changed" => true, "daily_kinds" => %w[code_review challenge])

    patch profile_path, params: { user: { section_kind_weights: {}, section_kind_preferences_version: stale },
                                  layout: %w[code_review challenge] }.to_json, headers: json
    expect(JSON.parse(response.body)).to include("layout_changed" => false)
  end
end
