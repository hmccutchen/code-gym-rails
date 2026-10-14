require "rails_helper"

RSpec.describe "Level suggestion card", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }

  def track_user(levels = LearningTrack.preset_levels)
    create_user_with_key.tap { |user| user.update!(learning_track: "junior", section_kind_levels: levels) }
  end

  # sections maps a kind to its rung, or to { rung:, ai:, self: } when a day needs other ratings.
  def reviewed_day(user, date, sections, too_hard: [])
    sections = sections.transform_values { |section| section.is_a?(Hash) ? section : { rung: section } }
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current,
      problem_set: sections.transform_values { |section| { "question" => "q", "snippet" => "s", "pitched_at" => section[:rung] } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: sections.transform_values { "a" * 20 },
      section_ratings: sections.to_h { |key, section| [ key, section[:self] || (too_hard.include?(key) ? "too_hard" : "right_level") ] },
      ai_review: sections.transform_values do |section|
        { "rating" => section.fetch(:ai, "solid"), "correct" => "c", "rubric" => AiService::RUBRIC_VERSION }
      end
    )
  end

  # Columns are written directly so the setup itself records no level-change cutoff.
  def account_off_track(**columns)
    create_user_with_key.tap { |user| user.update_columns(columns) }
  end

  def reviewed_window(user, sections, ending: Date.current, count: LevelSuggestion::WINDOW)
    count.times { |ago| reviewed_day(user, ending - ago, sections) }
  end

  def proposed_kinds
    Nokogiri::HTML(response.body).css("#level-suggestion [data-kind]").map { |element| element["data-kind"] }
  end

  def proposal_text
    Nokogiri::HTML(response.body).at_css("#level-suggestion")&.text.to_s
  end

  def apply_levels(user, levels)
    patch profile_path, params: {
      user: { section_kind_levels: levels, section_kind_preferences_version: user.reload.section_kind_preferences_version }
    }.to_json, headers: json
    expect(response).to have_http_status(:ok)
  end

  def dismiss(kinds)
    post level_suggestion_dismissal_path, params: { kinds: kinds }.to_json, headers: json
  end

  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  def kind_name(key) = I18n.t("sections.#{key}.name")

  it "offers one rung up after five code reviews, counting the favourable ones from the evidence" do
    user = track_user
    reviewed_day(user, Date.current - 4, { "code_review" => { rung: "junior", ai: "developing" } })
    reviewed_window(user, { "code_review" => "junior" }, count: 4)
    login_as(user)

    get root_path

    expect(proposal_text).to include("4 of your last 5 Code Review sections were reviewed solid or better. " \
                                     "Try Code Review at mid-level?")
    expect(proposed_kinds).to eq([ "code_review" ])
    step = Nokogiri::HTML(response.body).at_css("#level-suggestion [data-step]")
    expect(step["data-to"]).to eq("mid_level")
    expect(step["data-from"]).to eq("junior")
    expect(Nokogiri::HTML(response.body).css("#level-suggestion [data-remove-step]")).to be_empty
    box = Nokogiri::HTML(response.body).at_css("#level-suggestion")
    expect(JSON.parse(box["data-level-suggestion-levels-value"])).to eq(user.section_kind_levels)
    expect(box["data-level-suggestion-version-value"]).to eq(user.reload.section_kind_preferences_version.to_s)
    expect(box["data-level-suggestion-url-value"]).to eq(profile_path)
    expect(box["data-level-suggestion-dismiss-url-value"]).to eq(level_suggestion_dismissal_path)
  end

  it "offers nothing on four results, however good" do
    user = track_user
    reviewed_window(user, { "code_review" => "junior" }, count: LevelSuggestion::WINDOW - 1)
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "ignores results graded before the rubric" do
    user = track_user
    reviewed_window(user, { "code_review" => "junior" })
    user.daily_responses.find_by!(date: Date.current - 4).tap do |day|
      day.update!(ai_review: { "code_review" => day.ai_review["code_review"].except("rubric") })
    end
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "lists several kinds moving to the same level in one card, each with its own keep button" do
    user = track_user
    reviewed_window(user, { "code_review" => "junior", "pattern" => "junior" })
    login_as(user)

    get root_path

    expect(proposal_text).to include("These sections can move up to mid-level:",
                                     "Code Review: 5 of your last 5 were reviewed solid or better",
                                     "Pattern of the Month: 5 of your last 5 were reviewed solid or better")
    expect(proposed_kinds).to eq(%w[code_review pattern])
    buttons = Nokogiri::HTML(response.body).css("#level-suggestion [data-remove-step]")
    expect(buttons.map(&:text)).to eq([ "Keep at junior", "Keep at junior" ])
    expect(buttons.map { |button| button["aria-label"] }).to eq(
      [ "Keep #{kind_name("code_review")} at junior", "Keep #{kind_name("pattern")} at junior" ]
    )
  end

  it "offers a mid-level kind senior, and keeps kinds bound for another level out of its card" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "mid_level"))
    reviewed_window(user, { "code_review" => "mid_level", "pattern" => "junior" })
    login_as(user)

    get root_path

    expect(proposal_text).to include("5 of your last 5 Code Review sections were reviewed solid or better. " \
                                     "Try Code Review at senior?")
    expect(proposed_kinds).to eq([ "code_review" ])
    expect(Nokogiri::HTML(response.body).at_css("#level-suggestion [data-step]")["data-to"]).to eq("senior")
  end

  it "offers nothing to a senior kind with good results, since principal engineer is never suggested" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    reviewed_window(user, { "code_review" => "senior" })
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "lists no kind without five results of its own, even when another kind is targeted higher" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    reviewed_window(user, { "code_review" => "senior", "pattern" => "junior" }, count: LevelSuggestion::WINDOW - 1)
    reviewed_day(user, Date.current - 4, { "code_review" => "senior" })
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "describes a step back honestly when only two results exist" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    [ 1, 0 ].each do |ago|
      reviewed_day(user, Date.current - ago, { "code_review" => { rung: "senior", ai: "developing", self: "too_hard" } })
    end
    login_as(user)

    get root_path

    expect(proposal_text).to include("2 of your last 2 Code Review sections at senior felt too hard. " \
                                     "Move Code Review to mid-level?")
    expect(Nokogiri::HTML(response.body).at_css("#level-suggestion [data-step]")["data-to"]).to eq("mid_level")
  end

  it "counts a step back over the latest three when more results exist" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "mid_level"))
    reviewed_window(user, { "code_review" => { rung: "mid_level", ai: "developing", self: "too_hard" } }, count: 2)
    reviewed_window(user, { "code_review" => "mid_level" }, ending: Date.current - 2, count: 3)
    login_as(user)

    get root_path

    expect(proposal_text).to include("2 of your last 3 Code Review sections at mid-level felt too hard. " \
                                     "Move Code Review to junior?")
  end

  it "offers no step back when the AI rated every too-hard result solid or better" do
    user = track_user(LearningTrack.preset_levels.merge("code_review" => "senior"))
    reviewed_window(user, { "code_review" => { rung: "senior", ai: "strong", self: "too_hard" } }, count: 2)
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "offers no step up when two of the latest three felt too hard" do
    user = track_user
    reviewed_window(user, { "code_review" => { rung: "junior", self: "too_hard" } }, count: 2)
    reviewed_window(user, { "code_review" => "junior" }, ending: Date.current - 2, count: 3)
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "sends a card of several kinds to Setup with every kind and their shared level" do
    user = track_user
    user.update!(track_proposals_answered: LevelSuggestion::IN_PLACE_ANSWERS)
    reviewed_window(user, { "code_review" => "junior", "pattern" => "junior" })
    login_as(user)

    get root_path

    link = Nokogiri::HTML(response.body).at_css("#level-suggestion [data-change-in-setup]")
    expect(link["href"]).to eq(setup_path(suggested: %w[code_review pattern], suggested_level: "mid_level", anchor: "exercise-mix"))
    expect(Nokogiri::HTML(response.body).css("#level-suggestion [data-remove-step]")).to be_empty
  end

  it "does not offer a locked kind" do
    user = track_user
    user.update!(locked_section_kinds: [ "code_review" ])
    reviewed_window(user, { "code_review" => "junior" })
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "does not compute or render a proposal before submission" do
    user = track_user
    reviewed_window(user, { "code_review" => "junior" })
    user.daily_responses.find_by!(date: Date.current).update!(submitted_at: nil, ai_review: {})
    login_as(user)
    expect(LevelSuggestion).not_to receive(:for)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  [ nil, "none" ].each do |track|
    it "offers an untargeted kind one rung past the skill level with learning_track #{track.inspect}" do
      user = account_off_track(skill_level: "junior")
      user.update!(learning_track: track)
      reviewed_window(user, { "code_review" => "junior" })
      login_as(user)

      get root_path

      expect(proposed_kinds).to eq([ "code_review" ])
      expect(Nokogiri::HTML(response.body).at_css("#level-suggestion [data-step]")["data-to"]).to eq("mid_level")
    end
  end

  it "reads an untargeted kind at the skill level, not at junior" do
    user = account_off_track(skill_level: "mid_level")
    reviewed_window(user, { "code_review" => "mid_level", "pattern" => "junior" })
    login_as(user)

    get root_path

    expect(proposed_kinds).to eq([ "code_review" ])
    expect(Nokogiri::HTML(response.body).at_css("#level-suggestion [data-step]")["data-to"]).to eq("senior")
  end

  it "applies one target for an account off the track and leaves its skill level alone" do
    user = account_off_track(skill_level: "junior")
    reviewed_window(user, { "code_review" => "junior" })
    login_as(user)
    get root_path
    expect(proposed_kinds).to eq([ "code_review" ])

    apply_levels(user, { "code_review" => "mid_level" })

    expect(user.reload.section_kind_levels).to eq("code_review" => "mid_level")
    expect(user.skill_level).to eq("junior")
    expect(user.level_suggestion_events.sole).to have_attributes(kind: "code_review", source: "suggestion",
                                                                 from_level: "junior", to_level: "mid_level")
    get root_path
    expect(response.body).not_to include("level-suggestion")
  end

  it "refuses an Apply whose card showed a rung the skill level has since moved" do
    user = account_off_track(skill_level: "junior")
    login_as(user)
    patch profile_path, params: { user: { skill_level: "senior" } }.to_json, headers: json
    expect(response).to have_http_status(:ok)

    patch profile_path, params: {
      user: { section_kind_levels: { "code_review" => "mid_level" },
              section_kind_preferences_version: user.reload.section_kind_preferences_version },
      expected_rungs: { "code_review" => "junior" }
    }.to_json, headers: json

    expect(response).to have_http_status(:conflict)
    expect(user.reload.section_kind_levels).to eq({})
  end

  it "applies when the card's rungs still hold" do
    user = account_off_track(skill_level: "junior")
    login_as(user)

    patch profile_path, params: {
      user: { section_kind_levels: { "code_review" => "mid_level" },
              section_kind_preferences_version: user.reload.section_kind_preferences_version },
      expected_rungs: { "code_review" => "junior" }
    }.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(user.reload.section_kind_levels).to eq("code_review" => "mid_level")
  end

  it "records cutoffs, under the row lock, when the skill level is saved from Setup" do
    user = account_off_track(skill_level: "junior", section_kind_levels: { "pattern" => "senior" })
    login_as(user)
    expect_any_instance_of(User).to receive(:with_lock).and_call_original

    patch profile_path, params: { user: { skill_level: "mid_level" } }.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(user.reload.level_suggestion_cutoffs.keys).to match_array(ExerciseSection.keys - [ "pattern" ])
    expect(user.level_suggestion_events).to be_empty
  end

  it "offers nothing to an untargeted kind while the skill level is principal engineer" do
    user = account_off_track(skill_level: "principal_engineer")
    reviewed_window(user, { "code_review" => "principal_engineer" })
    login_as(user)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "shows nothing to an account that turned suggestions off" do
    user = account_off_track(level_suggestions: false)
    reviewed_window(user, { "code_review" => "junior" })
    login_as(user)
    expect(LevelSuggestion).not_to receive(:for)

    get root_path

    expect(response.body).not_to include("level-suggestion")
  end

  it "does not flap across a senior to mid-level to senior cycle" do
    levels = LearningTrack.preset_levels.merge("architecture" => "senior")
    user = track_user(levels)
    reviewed_window(user, { "architecture" => "mid_level" }, ending: Date.current - 2)
    reviewed_window(user, { "architecture" => { rung: "senior", ai: "developing", self: "too_hard" } }, count: 2)
    login_as(user)
    get root_path
    expect(proposal_text).to include("Move #{kind_name("architecture")} to mid-level?")
    apply_levels(user, levels.merge("architecture" => "mid_level"))

    get root_path
    expect(response).to have_http_status(:ok)
    expect(proposed_kinds).not_to include("architecture")

    LevelSuggestion::WINDOW.times do
      travel 1.day
      reviewed_day(user, Date.current, { "architecture" => "mid_level" })
    end
    login_as(user)
    get root_path
    expect(proposed_kinds).to eq([ "architecture" ])
    expect(proposal_text).to include("Try #{kind_name("architecture")} at senior?")
    apply_levels(user, levels)

    travel 1.day
    reviewed_day(user, Date.current, { "code_review" => "junior" })
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
    expect(user.level_suggestion_cutoffs).to eq({})
  end

  it "clears the track on the final Apply and keeps the senior targets" do
    user = track_user(LearningTrack.preset_levels.transform_values { "senior" }.merge("pattern" => "mid_level"))
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

      post level_suggestion_dismissal_path, params: {
        kinds: %w[code_review architecture], through: "2099-01-01", user_id: other.id
      }.to_json, headers: json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("dismissed" => %w[code_review architecture])
      expect(user.reload.level_suggestion_cutoffs).to eq(
        "code_review" => { "level" => "junior", "through" => (Date.current - 1).iso8601 },
        "architecture" => { "level" => "junior", "through" => (Date.current - 1).iso8601 }
      )
      expect(other.reload.level_suggestion_cutoffs).to eq({})
    end

    it "uses the user's today when no reviewed evidence exists" do
      user = track_user
      user.update!(time_zone: "Tokyo")
      login_as(user)

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs.dig("pattern", "through")).to eq("2026-10-15")
    end

    [ nil, [], "pattern", [ nil ], [ {} ], [ "unknown" ], %w[pattern unknown] ].each do |kinds|
      it "refuses malformed or unknown kinds #{kinds.inspect} atomically" do
        user = track_user
        login_as(user)
        dismiss(kinds)

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.level_suggestion_cutoffs).to eq({})
      end
    end

    it "refuses an unknown registry key even if historical stored levels contain it" do
      user = track_user
      user.update_column(:section_kind_levels, user.section_kind_levels.merge("unknown" => "junior"))
      login_as(user)
      dismiss([ "unknown" ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "refuses a kind targeted at principal engineer" do
      user = track_user(LearningTrack.preset_levels.merge("architecture" => "principal_engineer"))
      login_as(user)
      dismiss(%w[pattern architecture])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "refuses an untargeted kind while the skill level is principal engineer" do
      user = account_off_track(skill_level: "principal_engineer", section_kind_levels: { "pattern" => "junior" })
      login_as(user)
      dismiss(%w[pattern architecture])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "records an untargeted kind's cutoff at the skill level's rung" do
      user = account_off_track(skill_level: "mid_level")
      login_as(user)
      dismiss([ "architecture" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs).to eq(
        "architecture" => { "level" => "mid_level", "through" => Date.current.iso8601 }
      )
    end

    it "sets aside a kind at mid-level" do
      user = track_user(LearningTrack.preset_levels.merge("pattern" => "mid_level"))
      login_as(user)

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs["pattern"]).to eq("level" => "mid_level", "through" => Date.current.iso8601)
    end


    it "requires authentication" do
      dismiss([ "code_review" ])
      expect(response).to redirect_to(login_path)
    end

    it "keeps a cutoff another request wrote while this one was running" do
      user = track_user
      login_as(user)
      concurrent = { "architecture" => { "level" => "junior", "through" => Date.current.iso8601 } }
      allow(LevelSuggestion::Evidence).to receive(:for).and_wrap_original do |original, *args|
        User.find(user.id).update_column(:level_suggestion_cutoffs, concurrent)
        original.call(*args)
      end

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs).to eq(
        concurrent.merge("pattern" => { "level" => "junior", "through" => Date.current.iso8601 })
      )
    end

    it "keeps a newer same-kind dismissal when an older evidence read finishes last" do
      user = track_user
      reviewed_day(user, Date.current - LevelSuggestion::WINDOW, { "code_review" => "junior" })
      login_as(user)
      other_tab = ActionDispatch::Integration::Session.new(Rails.application)
      other_tab.post login_path, params: { email: user.email }
      other_tab.post verify_login_code_path, params: { code: user.generate_login_code! }
      advanced = false
      allow(LevelSuggestion::Evidence).to receive(:for).and_wrap_original do |original, *args|
        evidence = original.call(*args)
        unless advanced
          advanced = true
          reviewed_window(user, { "code_review" => "junior" })
          other_tab.post level_suggestion_dismissal_path, params: { kinds: [ "code_review" ] }.to_json, headers: json
          expect(other_tab.response).to have_http_status(:ok)
          expect(user.reload.level_suggestion_cutoffs.dig("code_review", "through")).to eq(Date.current.iso8601)
        end
        evidence
      end

      dismiss([ "code_review" ])

      expect(response).to have_http_status(:ok)
      aggregate_failures do
        expect(user.reload.level_suggestion_cutoffs.dig("code_review", "through")).to eq(Date.current.iso8601)
        expect(LevelSuggestion.for(user)).to be_nil
      end
    end

    it "keeps a level-change cutoff later than the latest review" do
      user = track_user
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)
      apply_levels(user, user.section_kind_levels.merge("pattern" => "senior"))

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs["pattern"]).to eq(
        "level" => "senior", "through" => Date.current.iso8601
      )
    end

    it "advances an older cutoff at the same level" do
      user = track_user
      user.update!(level_suggestion_cutoffs: { "pattern" => { "level" => "junior", "through" => "2026-10-12" } })
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs["pattern"]).to eq("level" => "junior", "through" => "2026-10-13")
    end

    [ nil, "junk", [], {}, { "through" => "2099-01-01" }, { "level" => "junior" },
      { "level" => "junior", "through" => "not a date" },
      { "level" => "junior", "through" => "2099-02-30" },
      { "level" => "senior", "through" => "2099-01-01" } ].each do |entry|
      it "replaces an inapplicable historical cutoff #{entry.inspect}" do
        user = track_user
        user.update!(level_suggestion_cutoffs: { "pattern" => entry })
        reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
        login_as(user)

        dismiss([ "pattern" ])

        expect(response).to have_http_status(:ok)
        expect(user.reload.level_suggestion_cutoffs["pattern"]).to eq("level" => "junior", "through" => "2026-10-13")
      end
    end

    it "rechecks the rung after another request changes the skill level" do
      user = account_off_track(skill_level: "junior")
      login_as(user)
      allow(LevelSuggestion::Evidence).to receive(:for).and_wrap_original do |original, *args|
        User.find(user.id).update!(skill_level: "principal_engineer")
        original.call(*args)
      end

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "uses a target another request changed before taking the lock" do
      user = track_user
      reviewed_day(user, Date.current - 1, { "code_review" => "junior" })
      login_as(user)
      changed = false
      allow(LevelSuggestion::Evidence).to receive(:for).and_wrap_original do |original, *args|
        unless changed
          changed = true
          fresh = User.find(user.id)
          fresh.update!(section_kind_levels: fresh.section_kind_levels.merge("pattern" => "senior"))
        end
        original.call(*args)
      end

      dismiss([ "pattern" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.level_suggestion_cutoffs.dig("pattern", "level")).to eq("senior")
      expect(user.level_suggestion_cutoffs.dig("pattern", "through")).to eq(Date.current.iso8601)
    end
  end
end
