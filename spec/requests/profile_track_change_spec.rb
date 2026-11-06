require "rails_helper"

RSpec.describe "Profile track preview and Apply", type: :request do
  let(:headers) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def preview(level = "senior", **extra)
    post profile_track_preview_path, params: { user: { skill_level: level }.merge(extra) }.to_json, headers: headers
    response.parsed_body
  end

  def apply_track(confirmation, level: "senior", **extra)
    patch profile_path, params: { user: { skill_level: level }.merge(extra), track_change: confirmation }.to_json, headers: headers
  end

  [ [], %w[code_review pattern challenge] ].each do |locks|
    it "preserves old, new and other-rung targets on upward and downward Apply with locks #{locks.inspect}" do
      targets = { "code_review" => "junior", "pattern" => "senior", "challenge" => "mid_level" }
      user.update!(section_kind_levels: targets, locked_section_kinds: locks)
      [ "senior", "junior" ].each do |destination|
        apply_track(preview(destination)["track_change"], level: destination)

        expect(response).to have_http_status(:ok)
        expect(user.reload).to have_attributes(skill_level: destination, section_kind_levels: targets, locked_section_kinds: locks)
        expect(user.level_suggestion_cutoffs.keys & targets.keys).to be_empty
        expect(user.level_suggestion_events.where(kind: targets.keys)).to be_empty
      end
    end
  end

  it "previews every consequence without writing any user state or events" do
    user.update!(section_kind_levels: { "code_review" => "junior", "pattern" => "senior", "challenge" => "mid_level" },
                 locked_section_kinds: [ "pattern" ], section_kind_weights: { "security_review" => 0.25 },
                 excluded_section_kinds: [ "architecture" ])
    before = user.reload.attributes

    body = preview

    expect(response).to have_http_status(:ok)
    expect(body["track_change"]).to eq("from" => "junior", "to" => "senior", "preferences_version" => user.section_kind_preferences_version)
    expect(body["preview_html"]).to include("Code Review", "Junior", "Senior", "locked", "Mid-level", "Design Comparison")
    expect(user.reload.attributes).to eq(before)
    expect(user.level_suggestion_events).to be_empty

    apply_track(body["track_change"])

    expect(response).to have_http_status(:ok)
    expect(user.reload.attributes.slice(*%w[section_kind_levels locked_section_kinds section_kind_weights excluded_section_kinds section_kind_preferences_version]))
      .to eq(before.slice(*%w[section_kind_levels locked_section_kinds section_kind_weights excluded_section_kinds section_kind_preferences_version]))
    expect(user.skill_level).to eq("senior")
    moved = ExerciseSection.keys - user.section_kind_levels.keys
    expect(user.level_suggestion_cutoffs.keys).to match_array(moved)
    expect(user.level_suggestion_events.pluck(:kind, :source)).to match_array(moved.map { |kind| [ kind, "skill_level_edit" ] })
    expect(response.parsed_body).to include("skill_level" => "senior", "kind_rungs" => user.kind_rungs)
    expect(response.parsed_body.dig("preferences", "section_kind_levels")).to eq(user.section_kind_levels)
  end

  it "applies an all-targeted baseline change without false movement or a version bump" do
    user.update!(section_kind_levels: ExerciseSection.keys.index_with { "junior" })
    version = user.section_kind_preferences_version
    body = preview
    expect(body["preview_html"]).to include(I18n.t("tracks.preview.baseline_only"))

    apply_track(body["track_change"])

    expect(response).to have_http_status(:ok)
    expect(user.reload).to have_attributes(skill_level: "senior", section_kind_preferences_version: version,
                                          section_kind_levels: ExerciseSection.keys.index_with { "junior" }, level_suggestion_cutoffs: {})
    expect(user.level_suggestion_events).to be_empty
    body = preview
    expect(body["already_saved"]).to be(true)
    expect(body["preview_html"]).to include(I18n.t("tracks.preview.already_saved"))
    expect(body["preview_html"]).not_to include(I18n.t("tracks.preview.baseline_only"))
  end

  it "refuses missing, open, malformed and mismatched confirmations before any mutation" do
    good = preview["track_change"]
    before = user.reload.attributes
    [ nil, "senior", [], {}, good.merge("extra" => true), good.except("from"),
      good.merge("from" => "unknown"), good.merge("to" => "mid_level"),
      good.merge("preferences_version" => "0"), good.merge("preferences_version" => -1),
      good.merge("preferences_version" => 0.0) ].each do |confirmation|
      apply_track(confirmation, time_zone: "America/Chicago")
      expect(response).to have_http_status(:unprocessable_content), confirmation.inspect
      expect(response.parsed_body["error"]).to eq(I18n.t("tracks.preview.invalid_confirmation"))
      expect(user.reload.attributes).to eq(before)
    end
    expect(user.level_suggestion_events).to be_empty
  end

  it "refuses an older preference version and supplies the actual saved baseline" do
    confirmation = preview["track_change"]
    user.update!(section_kind_levels: { "pattern" => "mid_level" })
    before = user.reload.attributes

    apply_track(confirmation)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("skill_level" => "junior")
    expect(response.parsed_body.dig("current", "section_kind_levels")).to eq("pattern" => "mid_level")
    expect(user.reload.attributes).to eq(before)
  end

  it "refuses a stale baseline even when another Apply did not increment the preference version" do
    first = preview["track_change"]
    second = preview("mid_level")["track_change"]
    version = user.section_kind_preferences_version
    apply_track(second, level: "mid_level")
    expect(response).to have_http_status(:ok)
    before = user.reload.attributes
    expect(user.section_kind_preferences_version).to eq(version)

    apply_track(first)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["skill_level"]).to eq("mid_level")
    expect(user.reload.attributes).to eq(before)
  end

  it "requires a new confirmation after a successful write whose reply was lost" do
    confirmation = preview["track_change"]
    apply_track(confirmation)
    before = user.reload.attributes
    events = user.level_suggestion_events.count

    apply_track(confirmation)

    expect(response).to have_http_status(:conflict)
    body = preview
    expect(body).to include("already_saved" => true, "skill_level" => "senior", "kind_rungs" => user.kind_rungs)
    expect(body["preferences"]).to include("section_kind_levels" => user.section_kind_levels)
    expect(user.reload.attributes).to eq(before)
    expect(user.level_suggestion_events.count).to eq(events)
  end

  it "refuses track-plus-mix writes and the first-run exception on an existing account" do
    confirmation = preview["track_change"]
    apply_track(confirmation, section_kind_levels: {})
    expect(response).to have_http_status(:unprocessable_content)
    apply_track(nil, choose_track: true)
    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.skill_level).to eq("junior")
  end

  it "rejects malformed or cross-user-shaped previews and reads only the signed-in user" do
    other = create_user_with_key(email: "other-track@example.com")
    originals = [ user, other ].map { |account| account.reload.attributes }
    [ nil, [], "senior", {}, { skill_level: "unknown" }, { skill_level: "senior", id: other.id } ].each do |payload|
      post profile_track_preview_path, params: { user: payload }.to_json, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
    post profile_track_preview_path, params: { id: other.id, user: { skill_level: "senior" } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    apply_track(response.parsed_body["track_change"])
    expect(user.reload.skill_level).to eq("senior")
    expect(other.reload.attributes).to eq(originals.last)
  end

  it "requires authentication for preview" do
    delete logout_path
    post profile_track_preview_path, params: { user: { skill_level: "senior" } }.to_json, headers: headers

    expect(response).not_to have_http_status(:ok)
    expect(user.reload.skill_level).to eq("junior")
  end
end
