require "rails_helper"

RSpec.describe "Changing the track on Setup", type: :system, with_csrf: true do
  let(:targets) { ExerciseSection.keys.index_with { "junior" }.merge("pattern" => "senior") }
  let(:user) do
    create_fake_provider_user.tap do |account|
      account.update!(skill_level: "junior", section_kind_levels: targets, locked_section_kinds: [ "challenge" ])
      DailyExercise.create!(user: account, date: Date.yesterday, generated_at: 1.day.ago,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
    end
  end

  def open_setup(**params)
    visit_as(user)
    visit setup_path(**params)
    find("#exercise-mix summary").click unless find("#exercise-mix")[:open]
  end

  def checked_level(kind)
    find(".mix-difficulty[data-kind='#{kind}'] input[type=radio]:checked", visible: :all).value
  end

  def choose_level(kind, level)
    find(".mix-difficulty[data-kind='#{kind}'] input[value='#{level}']").click
  end

  def preview_track(label = "Mid-level")
    find("#skill-level", visible: :all).select(label, visible: :all)
    expect(page).to have_button("Apply track", disabled: false)
  end

  def applied(level = "mid_level")
    wait_for { user.reload.skill_level == level }
    expect(page).to have_no_button("Apply track")
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
  end

  def move_weight(value)
    page.execute_script(<<~JS, value.to_s)
      const slider = document.querySelector("#weight-security_review");
      slider.value = arguments[0] === "default" ? slider.defaultValue : arguments[0];
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
  end

  def hold_profile(field, fail: false)
    page.execute_script(<<~JS, field, fail)
      const field = arguments[0], fail = arguments[1], send = window.fetch;
      let held = false;
      window.fetch = (url, options) => {
        const body = options?.body ? JSON.parse(options.body) : {};
        if (!held && url.endsWith("/profile") && Object.hasOwn(body.user || {}, field)) {
          held = true;
          return new Promise((resolve, reject) => {
            window.releaseProfile = () => fail ? reject(new TypeError("offline")) : resolve(send(url, options));
          });
        }
        return send(url, options);
      };
    JS
  end

  def wait_for_held_profile
    wait_for_js_condition("typeof window.releaseProfile === 'function'")
  end

  it "applies without a reload, preserves every target and lock, and lets the next mix edit save" do
    open_setup
    page.execute_script("window.sameDocument = true")
    preview_track

    expect(user.reload.skill_level).to eq("junior")
    expect(page).to have_content(I18n.t("tracks.preview.baseline_only"))
    click_button "Apply track"
    applied

    expect(find('[data-profile-preferences-target="keptOwnLevel"]').text).to include("Pattern", "Senior", "Junior, locked")
    expect(user.reload.section_kind_levels).to eq(targets)
    expect(user.locked_section_kinds).to eq([ "challenge" ])
    expect(checked_level("code_review")).to eq("junior")
    choose_level("code_review", "senior")
    wait_for { user.reload.section_kind_levels["code_review"] == "senior" }
    expect(page).to have_no_css("#save-status")
    expect(page.evaluate_script("window.sameDocument")).to be(true)
  end

  it "waits for the pending 400ms mix edit before previewing its retained target and lock" do
    open_setup
    choose_level("code_review", "mid_level")
    find(".mix-difficulty[data-kind='code_review'] .mix-lock-box").click
    preview_track

    expect(user.reload.skill_level).to eq("junior")
    expect(user.section_kind_levels["code_review"]).to eq("mid_level")
    expect(user.locked_section_kinds).to include("code_review")
    expect(find('[data-profile-preferences-target="preview"]').text).to include("Code Review (Mid-level, locked)")
    click_button "Apply track"
    applied
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
    expect(user.locked_section_kinds).to include("code_review")
  end

  it "cancels only the proposed track while keeping accepted weights, targets, exclusions and locks" do
    open_setup
    move_weight(0)
    choose_level("code_review", "senior")
    find(".mix-difficulty[data-kind='code_review'] .mix-lock-box").click
    find("#exclude-architecture").click
    preview_track
    saved = user.reload.attributes

    click_button "Cancel track change"

    expect(user.reload.attributes).to eq(saved)
    expect(checked_level("code_review")).to eq("senior")
    expect(page).to have_css("#weight-security_review[value]", visible: :all)
    expect(find("#exclude-architecture")).to be_checked
    expect(find("#skill-level", visible: :all).value).to eq("junior")
  end

  it "invalidates a preview on a mix edit and waits for that save before enabling Apply again" do
    open_setup
    preview_track
    hold_profile("section_kind_levels")
    choose_level("code_review", "mid_level")
    wait_for_held_profile

    expect(page).to have_button("Apply track", disabled: true)
    expect(user.reload.skill_level).to eq("junior")
    page.execute_script("window.releaseProfile()")
    expect(page).to have_button("Apply track", disabled: false)
    expect(find('[data-profile-preferences-target="preview"]').text).to include("Code Review (Mid-level)")
    click_button "Apply track"
    applied
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
  end

  it "does not send a cancelled preview after its pending-mix wait finishes" do
    open_setup
    hold_profile("section_kind_levels")
    choose_level("code_review", "mid_level")
    wait_for_held_profile
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.previewedLevels = [];
      window.fetch = (url, options) => {
        if (url.endsWith("/profile/track_preview")) window.previewedLevels.push(JSON.parse(options.body).user.skill_level);
        return send(url, options);
      };
    JS
    find("#skill-level", visible: :all).select("Senior", visible: :all)
    click_button "Cancel track change"
    find("#skill-level", visible: :all).select("Mid-level", visible: :all)
    page.execute_script("window.releaseProfile()")

    expect(page).to have_button("Apply track", disabled: false)
    expect(page.evaluate_script("window.previewedLevels")).to eq([ "mid_level" ])
    expect(user.reload).to have_attributes(skill_level: "junior", section_kind_levels: targets.merge("code_review" => "mid_level"))
  end

  it "requires another explicit Apply when another tab changes preferences after the preview" do
    open_setup
    preview_track
    user.update!(section_kind_levels: targets.merge("code_review" => "mid_level"))
    click_button "Apply track"

    expect(page).to have_content(I18n.t("tracks.preview.stale"))
    expect(page).to have_button("Apply track", disabled: false)
    expect(user.reload.skill_level).to eq("junior")
    expect(find('[data-profile-preferences-target="preview"]').text).to include("Code Review (Mid-level)")
    click_button "Apply track"
    applied
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
  end

  it "refreshes a baseline-only conflict and Cancel restores the actual saved track" do
    open_setup
    preview_track
    version = user.section_kind_preferences_version
    user.update!(skill_level: "senior")
    expect(user.section_kind_preferences_version).to eq(version)
    click_button "Apply track"

    expect(page).to have_content(I18n.t("tracks.preview.stale"))
    expect(page).to have_button("Apply track", disabled: false)
    expect(user.reload.skill_level).to eq("senior")
    click_button "Cancel track change"
    expect(find("#skill-level", visible: :all).value).to eq("senior")
    expect(page).to have_css("[data-skill-level-label]", text: "Your track (Senior)", visible: :all)
  end

  it "sends the displayed confirmation unchanged behind a queued predecessor and refuses stale consequences" do
    open_setup
    preview_track
    hold_profile("section_kind_weights")
    version = user.reload.section_kind_preferences_version
    page.execute_script(<<~JS, profile_path, version)
      window.CodeGymSaveStatus.queue("exercise_mix", "PATCH", arguments[0], {
        user: { section_kind_weights: { security_review: 0.25 }, section_kind_preferences_version: arguments[1] }
      });
    JS
    wait_for_held_profile
    click_button "Apply track"
    page.execute_script("window.releaseProfile()")

    expect(page).to have_content(I18n.t("tracks.preview.stale"))
    expect(user.reload).to have_attributes(skill_level: "junior", section_kind_weights: { "security_review" => 0.25 })
    click_button "Apply track"
    applied
    expect(user.reload.section_kind_weights).to eq("security_review" => 0.25)
  end

  it "keeps newer locks and their targets while Apply is in flight" do
    open_setup
    preview_track
    hold_profile("skill_level")
    click_button "Apply track"
    wait_for_held_profile
    find(".mix-difficulty[data-kind='security_review'] .mix-lock-box").click
    expect(page).to have_css("#mix-ladder-preparation button[disabled]", visible: :all)
    page.execute_script("window.releaseProfile()")
    applied

    expect(user.reload.locked_section_kinds).to match_array(%w[challenge security_review])
    expect(user.section_kind_levels).to eq(targets)
    expect(checked_level("security_review")).to eq("junior")
    expect(page).to have_css("#mix-ladder-preparation button:not([disabled])", visible: :all)
    expect(page).to have_no_css("#save-status")
  end

  it "keeps a level chosen again during Apply even when it matches the previously saved value" do
    open_setup
    preview_track
    hold_profile("skill_level")
    click_button "Apply track"
    wait_for_held_profile
    choose_level("security_review", "senior")
    choose_level("security_review", "junior")
    page.execute_script("window.releaseProfile()")
    applied

    expect(user.reload.section_kind_levels).to eq(targets)
    expect(checked_level("security_review")).to eq("junior")
    expect(page).to have_no_css("#save-status")
  end

  it "keeps edits made during Apply while earlier mix saves are queued, and adopts their last values" do
    open_setup
    preview_track
    hold_profile("skill_level")
    click_button "Apply track"
    wait_for_held_profile
    move_weight(0)
    wait_for_js_condition('window.CodeGymSaveStatus.queued("exercise_mix")')
    move_weight(1)
    choose_level("design_comparison", "mid_level")
    page.execute_script("window.releaseProfile()")
    applied

    expect(user.reload).to have_attributes(
      section_kind_weights: { "security_review" => 0.5 },
      section_kind_levels: targets.merge("design_comparison" => "mid_level")
    )
    expect(checked_level("design_comparison")).to eq("mid_level")
    expect(page.evaluate_script('document.querySelector("#weight-security_review").value')).to eq("1")
    expect(page).to have_no_css("#save-status")
  end

  it "keeps a weight returned to its original value while the earlier save is in flight" do
    open_setup
    hold_profile("section_kind_weights")
    move_weight(0)
    wait_for_held_profile
    move_weight("default")
    find("#skill-level", visible: :all).select("Mid-level", visible: :all)
    page.execute_script("window.releaseProfile()")
    expect(page).to have_button("Apply track", disabled: false)
    click_button "Apply track"
    applied

    expect(user.reload.section_kind_weights).to eq({})
    expect(page.evaluate_script('document.querySelector("#weight-security_review").value')).to eq(
      page.evaluate_script('document.querySelector("#weight-security_review").defaultValue')
    )
  end

  it "resends an earlier failed weight in the following queued mix save before previewing" do
    open_setup
    hold_profile("section_kind_weights", fail: true)
    move_weight(0)
    wait_for_held_profile
    choose_level("design_comparison", "senior")
    wait_for_js_condition('window.CodeGymSaveStatus.queued("exercise_mix")')
    find("#skill-level", visible: :all).select("Mid-level", visible: :all)
    page.execute_script("window.releaseProfile()")
    expect(page).to have_button("Apply track", disabled: false)
    click_button "Apply track"
    applied

    expect(user.reload.section_kind_weights).to eq("security_review" => 0.25)
    expect(user.section_kind_levels["design_comparison"]).to eq("senior")
    expect(page).to have_no_css("#save-status")
  end

  it "does not ignore another setting's failed save when waiting to preview" do
    open_setup
    fail_requests_to(profile_path)
    move_weight(0)
    expect(page).to have_css("#save-status", text: "nope")
    find("#skill-level", visible: :all).select("Mid-level", visible: :all)

    expect(page).to have_content(I18n.t("tracks.preview.waiting"))
    expect(page).to have_button("Apply track", disabled: true)
    click_button "Cancel track change"
    expect(page).to have_css("#save-status", text: "nope")
    expect(user.reload.skill_level).to eq("junior")
  end

  it "shows a failed Apply as unsaved, permits refresh and retry, and releases guidance preparation" do
    open_setup
    preview_track
    hold_profile("skill_level", fail: true)
    click_button "Apply track"
    wait_for_held_profile
    expect(page).to have_css("#mix-ladder-preparation button[disabled]", visible: :all)
    page.execute_script("window.releaseProfile()")

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_button("Apply track", disabled: true)
    expect(page).to have_css("#skill-level:not([disabled])", visible: :all)
    expect(page).to have_css("#mix-ladder-preparation button:not([disabled])", visible: :all)
    expect(user.reload.skill_level).to eq("junior")
    click_button "Refresh preview"
    expect(page).to have_button("Apply track", disabled: false)
    click_button "Apply track"
    applied
  end

  it "forgets a shown suggestion only when an untargeted kind actually moves" do
    user.update!(section_kind_levels: targets.except("code_review"))
    open_setup(suggested: [ "code_review" ], suggested_level: "mid_level")
    preview_track("Senior")
    click_button "Apply track"
    applied("senior")
    choose_level("code_review", "mid_level")

    wait_for { user.reload.section_kind_levels["code_review"] == "mid_level" }
    expect(user.level_suggestion_events.where(kind: "code_review").last.source).to eq("setup_edit")
    expect(page).to have_no_css("#save-status")
  end

  it "holds focus during preview and returns it after Apply unless the user moved elsewhere" do
    open_setup
    preview_track
    hold_profile("skill_level")
    click_button "Apply track"
    wait_for_held_profile
    expect(page).to have_css("#skill-level[disabled]", visible: :all)
    page.execute_script("window.releaseProfile()")
    applied
    expect(page.evaluate_script("document.activeElement.id")).to eq("skill-level")

    preview_track("Senior")
    page.execute_script("window.releaseProfile = undefined")
    hold_profile("skill_level")
    click_button "Apply track"
    wait_for_held_profile
    page.execute_script('document.querySelector("#weight-security_review").focus()')
    page.execute_script("window.releaseProfile()")
    applied("senior")
    expect(page.evaluate_script("document.activeElement.id")).to eq("weight-security_review")
  end

  def guide_measurement
    page.evaluate_script(<<~JS)
      (() => {
        const guide = document.querySelector(".key-guide");
        const style = getComputedStyle(guide.querySelector(".hint"));
        return { fontSize: style.fontSize, documentWidth: document.documentElement.scrollWidth };
      })()
    JS
  end

  it "measures the key guide at phone width without hiding content or shrinking type" do
    fresh = User.create!(email: "keyless-#{SecureRandom.hex(3)}@example.com", **chosen_track(true))
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    visit_as(fresh)
    visit setup_path
    expect(page).to have_css(".key-guide")

    [ "100", "125", "140" ].each do |size|
      fresh.update!(display_preferences: size == "100" ? {} : { "text_size" => size })
      visit setup_path
      measurement = guide_measurement
      expect(measurement["documentWidth"]).to be <= 390
      expect(measurement["fontSize"].to_f).to be >= 12.8
      expect(page).to have_css(".key-guide li", count: 12)
      expect(page).to have_css(".key-guide p", text: "What it costs.")
    end
  end
end
