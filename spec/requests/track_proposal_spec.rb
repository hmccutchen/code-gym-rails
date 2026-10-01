require "rails_helper"

RSpec.describe "Learning track proposals", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }

  def track_user(levels = LearningTrack.preset_levels)
    create_user_with_key.tap { |user| user.update!(learning_track: "junior", section_kind_levels: levels) }
  end

  def reviewed_day(user, date, sections, too_hard: [])
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current,
      problem_set: sections.to_h { |key, rung| [ key, { "question" => "q", "snippet" => "s", "pitched_at" => rung } ] }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: sections.keys.index_with { "a" * 20 },
      section_ratings: sections.keys.index_with { |key| too_hard.include?(key) ? "too_hard" : "right_level" },
      ai_review: sections.keys.index_with { { "rating" => "solid", "correct" => "c" } }
    )
  end

  def proposed_kinds
    Nokogiri::HTML(response.body).css("#track-proposal [data-kind]").map { |element| element["data-kind"] }
  end

  def proposal_text
    Nokogiri::HTML(response.body).at_css("#track-proposal")&.text.to_s
  end

  def apply_levels(user, levels)
    patch profile_path, params: {
      user: { section_kind_levels: levels, section_kind_preferences_version: user.reload.section_kind_preferences_version }
    }.to_json, headers: json
    expect(response).to have_http_status(:ok)
  end

  def dismiss(kinds)
    post learning_track_dismissal_path, params: { kinds: kinds }.to_json, headers: json
  end

  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  it "shows an own-result proposal after three favourable code reviews" do
    user = track_user
    [ 2, 1, 0 ].each { |ago| reviewed_day(user, Date.current - ago, { "code_review" => "junior" }) }
    login_as(user)

    get root_path

    expect(proposal_text).to include("Move Code Review up to senior?")
    expect(proposed_kinds).to eq([ "code_review" ])
    box = Nokogiri::HTML(response.body).at_css("#track-proposal")
    expect(JSON.parse(box["data-levels"])).to eq(user.section_kind_levels)
    expect(box["data-version"]).to eq(user.reload.section_kind_preferences_version.to_s)
    expect(box["data-profile-url"]).to eq(profile_path)
    expect(box["data-dismiss-url"]).to eq(learning_track_dismissal_path)
  end

  it "bundles led kinds and names the registry's lead" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    reviewed_day(user, Date.current, { "code_review" => "senior", "pattern" => "junior" })
    login_as(user)

    get root_path

    expect(proposal_text).to include("Your Code Review sections are now set to senior.",
                                    "not enough sections to judge on its own yet",
                                    "none of your recent sections felt too hard")
    expect(proposed_kinds).to match_array(ExerciseSection.keys - [ "code_review" ])
  end

  it "names each section in its keep-at-junior button's accessible name" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    reviewed_day(user, Date.current, { "code_review" => "senior" })
    login_as(user)

    get root_path

    labels = Nokogiri::HTML(response.body).css("#track-proposal [data-remove-step]").map { |button| button["aria-label"] }
    expected = (ExerciseSection.keys - [ "code_review" ]).map { |key| "Keep #{I18n.t("sections.#{key}.name")} at junior" }
    expect(labels).to match_array(expected)
  end

  it "derives the led heading from the registry rather than a named kind" do
    user = track_user(LearningTrack.preset_levels.merge("pattern" => "senior"))
    reviewed_day(user, Date.current, { "code_review" => "junior" })
    login_as(user)
    allow(ExerciseSection).to receive(:learning_track_lead).and_return(ExerciseSection::Pattern)

    get root_path

    expect(proposal_text).to include("Your Pattern of the Month sections are now set to senior.")
  end

  # A lead set above senior by hand in Setup still leads, and the heading
  # names the level it is at rather than claiming a proposal moved it.
  it "names the lead's actual level when it was set to principal engineer by hand" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "principal_engineer"))
    reviewed_day(user, Date.current, { "code_review" => "principal_engineer" })
    login_as(user)

    get root_path

    expect(proposal_text).to include("Your Code Review sections are now set to principal engineer.")
    expect(proposal_text).not_to include("moved up")
  end

  it "describes a back step honestly when only two results exist" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    [ 1, 0 ].each do |ago|
      reviewed_day(user, Date.current - ago, { "code_review" => "senior" }, too_hard: [ "code_review" ])
    end
    login_as(user)

    get root_path

    expect(proposal_text).to include("Most of your recent Code Review sections at senior felt too hard")
    expect(proposal_text).to include("Move Code Review back to junior?")
  end

  it "does not compute or render a proposal before submission" do
    user = track_user
    [ 3, 2, 1, 0 ].each { |ago| reviewed_day(user, Date.current - ago, { "code_review" => "junior" }) }
    user.daily_responses.find_by!(date: Date.current).update!(submitted_at: nil, ai_review: {})
    login_as(user)
    expect(TrackGraduation).not_to receive(:for)

    get root_path

    expect(response.body).not_to include("track-proposal")
  end

  [ nil, "none" ].each do |track|
    it "shows nothing with learning_track #{track.inspect}" do
      user = create_user_with_key
      user.update!(learning_track: track)
      [ 2, 1, 0 ].each { |ago| reviewed_day(user, Date.current - ago, { "code_review" => "junior" }) }
      login_as(user)
      expect(TrackGraduation).not_to receive(:for)

      get root_path

      expect(response.body).not_to include("track-proposal")
    end
  end

  it "does not flap across a full senior to junior to senior cycle" do
    levels = LearningTrack.preset_levels.merge("code_review" => "senior", "architecture" => "senior")
    user = track_user(levels)
    [ 5, 4 ].each do |ago|
      reviewed_day(user, Date.current - ago, { "architecture" => "senior" }, too_hard: [ "architecture" ])
    end
    [ 3, 2, 1 ].each { |ago| reviewed_day(user, Date.current - ago, { "architecture" => "junior" }) }
    login_as(user)
    apply_levels(user, levels.merge("architecture" => "junior"))

    travel 1.day
    reviewed_day(user, Date.current, { "code_review" => "senior", "architecture" => "junior" })
    get root_path
    expect(response).to have_http_status(:ok)
    expect(proposed_kinds).not_to include("architecture")

    2.times do
      travel 1.day
      reviewed_day(user, Date.current, { "architecture" => "junior" })
    end
    login_as(user)
    get root_path
    expect(response).to have_http_status(:ok)
    expect(proposed_kinds).to eq([ "architecture" ])
    apply_levels(user, levels)

    travel 1.day
    reviewed_day(user, Date.current, { "code_review" => "senior" })
    get root_path
    expect(response).to have_http_status(:ok)
    expect(proposed_kinds).not_to include("architecture")
  end

  it "refuses Apply from a stale dashboard without losing the newer settings" do
    user = track_user
    version = user.section_kind_preferences_version
    login_as(user)
    user.update!(locked_section_kinds: [ "pattern" ])

    patch profile_path, params: { user: {
      section_kind_levels: user.section_kind_levels.merge("code_review" => "senior"),
      section_kind_preferences_version: version
    } }.to_json, headers: json

    expect(response).to have_http_status(:conflict)
    expect(user.reload.section_kind_levels["code_review"]).to eq("junior")
    expect(user.locked_section_kinds).to eq([ "pattern" ])
    expect(user.track_evidence_cutoffs).to eq({})
  end

  it "clears the track on the final Apply and keeps the senior targets" do
    user = track_user(LearningTrack.preset_levels.transform_values { "senior" }.merge("pattern" => "junior"))
    login_as(user)
    apply_levels(user, user.section_kind_levels.merge("pattern" => "senior"))

    expect(user.reload.learning_track).to eq("none")
    expect(user.section_kind_levels.values.uniq).to eq([ "senior" ])
  end

  describe "Not now" do
    it "stores the server's newest reviewed date for every posted kind, only on this user" do
      user = track_user
      other = create_user_with_key(email: "other@example.com")
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)

      post learning_track_dismissal_path, params: {
        kinds: %w[code_review architecture], through: "2099-01-01", user_id: other.id
      }.to_json, headers: json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("dismissed" => %w[code_review architecture])
      expect(user.reload.track_evidence_cutoffs).to eq(
        "code_review" => { "level" => "junior", "through" => (Date.current - 1).iso8601 },
        "architecture" => { "level" => "junior", "through" => (Date.current - 1).iso8601 }
      )
      expect(other.reload.track_evidence_cutoffs).to eq({})
    end

    it "uses the user's today when no reviewed evidence exists" do
      user = track_user
      user.update!(time_zone: "Tokyo")
      login_as(user)

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.track_evidence_cutoffs.dig("pattern", "through")).to eq("2026-10-15")
    end

    [ nil, [], "pattern", [ nil ], [ {} ], [ "unknown" ], %w[pattern unknown] ].each do |kinds|
      it "refuses malformed or unknown kinds #{kinds.inspect} atomically" do
        user = track_user
        login_as(user)
        dismiss(kinds)

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.track_evidence_cutoffs).to eq({})
      end
    end

    it "refuses an unknown registry key even if historical stored levels contain it" do
      user = track_user
      user.update_column(:section_kind_levels, user.section_kind_levels.merge("unknown" => "junior"))
      login_as(user)
      dismiss([ "unknown" ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.track_evidence_cutoffs).to eq({})
    end

    [ nil, "principal_engineer" ].each do |level|
      it "refuses a kind targeted at #{level.inspect}" do
        levels = LearningTrack.preset_levels.except("architecture")
        levels["architecture"] = level if level
        user = track_user(levels)
        login_as(user)
        dismiss(%w[pattern architecture])

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.track_evidence_cutoffs).to eq({})
      end
    end

    it "is not found for a user off the track" do
      login_as(create_user_with_key)
      dismiss([ "code_review" ])
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      dismiss([ "code_review" ])
      expect(response).to redirect_to(login_path)
    end

    it "keeps a cutoff another request wrote while this one was running" do
      user = track_user
      login_as(user)
      concurrent = { "architecture" => { "level" => "junior", "through" => Date.current.iso8601 } }
      allow(TrackGraduation::Evidence).to receive(:for).and_wrap_original do |original, *args|
        User.find(user.id).update_column(:track_evidence_cutoffs, concurrent)
        original.call(*args)
      end

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.track_evidence_cutoffs).to eq(
        concurrent.merge("pattern" => { "level" => "junior", "through" => Date.current.iso8601 })
      )
    end

    it "keeps a newer same-kind dismissal when an older evidence read finishes last" do
      user = track_user
      reviewed_day(user, Date.current - 3, { "code_review" => "junior" })
      login_as(user)
      other_tab = ActionDispatch::Integration::Session.new(Rails.application)
      other_tab.post login_path, params: { email: user.email }
      other_tab.post verify_login_code_path, params: { code: user.generate_login_code! }
      advanced = false
      allow(TrackGraduation::Evidence).to receive(:for).and_wrap_original do |original, *args|
        evidence = original.call(*args)
        unless advanced
          advanced = true
          [ 2, 1, 0 ].each { |ago| reviewed_day(user, Date.current - ago, { "code_review" => "junior" }) }
          other_tab.post learning_track_dismissal_path, params: { kinds: [ "code_review" ] }.to_json, headers: json
          expect(other_tab.response).to have_http_status(:ok)
          expect(user.reload.track_evidence_cutoffs.dig("code_review", "through")).to eq(Date.current.iso8601)
        end
        evidence
      end

      dismiss([ "code_review" ])

      expect(response).to have_http_status(:ok)
      aggregate_failures do
        expect(user.reload.track_evidence_cutoffs.dig("code_review", "through")).to eq(Date.current.iso8601)
        expect(TrackGraduation.for(user)).to be_nil
      end
    end

    it "keeps a level-change cutoff later than the latest review" do
      user = track_user
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)
      apply_levels(user, user.section_kind_levels.merge("pattern" => "senior"))

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.track_evidence_cutoffs["pattern"]).to eq(
        "level" => "senior", "through" => Date.current.iso8601
      )
    end

    it "advances an older cutoff at the same level" do
      user = track_user
      user.update!(track_evidence_cutoffs: { "pattern" => { "level" => "junior", "through" => "2026-10-12" } })
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.track_evidence_cutoffs["pattern"]).to eq("level" => "junior", "through" => "2026-10-13")
    end

    [ nil, "junk", [], {}, { "through" => "2099-01-01" }, { "level" => "junior" },
      { "level" => "junior", "through" => "not a date" },
      { "level" => "junior", "through" => "2099-02-30" },
      { "level" => "senior", "through" => "2099-01-01" } ].each do |entry|
      it "replaces an inapplicable historical cutoff #{entry.inspect}" do
        user = track_user
        user.update!(track_evidence_cutoffs: { "pattern" => entry })
        reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
        login_as(user)

        dismiss([ "pattern" ])

        expect(response).to have_http_status(:ok)
        expect(user.reload.track_evidence_cutoffs["pattern"]).to eq("level" => "junior", "through" => "2026-10-13")
      end
    end

    it "rechecks membership after another request leaves the track" do
      user = track_user
      login_as(user)
      allow(TrackGraduation::Evidence).to receive(:for).and_wrap_original do |original, *args|
        User.find(user.id).update!(learning_track: "none")
        original.call(*args)
      end

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:not_found)
      expect(user.reload.learning_track).to eq("none")
      expect(user.track_evidence_cutoffs).to eq({})
    end

    it "uses a target another request changed before taking the lock" do
      user = track_user
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)
      allow(TrackGraduation::Evidence).to receive(:for).and_wrap_original do |original, *args|
        fresh = User.find(user.id)
        fresh.update!(section_kind_levels: fresh.section_kind_levels.merge("pattern" => "senior"))
        original.call(*args)
      end

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.track_evidence_cutoffs.dig("pattern", "level")).to eq("senior")
      expect(user.track_evidence_cutoffs.dig("pattern", "through")).to eq(Date.current.iso8601)
    end
  end
end
