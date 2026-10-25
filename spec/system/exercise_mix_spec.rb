require "rails_helper"

RSpec.describe "Exercise mix", type: :system do
  let(:user) { create_fake_provider_user }

  # Poll until the value matches, not just until present: debounced saves can land an intermediate write first.
  def weights_after_save(expected)
    wait_for { user.reload.section_kind_weights == expected }
    user.reload.section_kind_weights
  end

  def exclusions_after_save(expected)
    wait_for { user.reload.excluded_section_kinds.sort == expected.sort }
    user.reload.excluded_section_kinds
  end

  def resize(width, height: 844)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: height) }
  end

  def open_mix_at(width)
    visit_as(user)
    visit setup_path
    resize(width)
    find("#exercise-mix summary").click
  end

  def set_forced_colors(value)
    page.driver.with_playwright_page do |pw|
      pw.context.new_cdp_session(pw).send_message("Emulation.setEmulatedMedia", params: { features: [ { name: "forced-colors", value: value } ] })
    end
  end

  def level_row(kind, value)
    "document.querySelector(\"input[name='level-#{kind}'][value='#{value}']\").closest('label')"
  end

  it "gives each difficulty row 48px, a 24px radio and a 48px lock row" do
    open_mix_at(390)

    rows = page.evaluate_script("Array.from(document.querySelectorAll('.mix-level')).map(r => r.getBoundingClientRect().height)")
    radios = page.evaluate_script("Array.from(document.querySelectorAll('.mix-level input')).map(r => [r.offsetWidth, r.offsetHeight])")
    locks = page.evaluate_script("Array.from(document.querySelectorAll('.mix-lock-box')).map(b => [b.closest('.switch-row').getBoundingClientRect().height, b.offsetWidth])")

    expect(rows).not_to be_empty
    expect(rows).to all(be >= 48)
    expect(radios.flatten).to all(be >= 24)
    expect(locks.map(&:first)).to all(be >= 48)
    expect(locks.map(&:last)).to all(be >= 44)
  end

  it "checks a row's radio from a tap at its right edge" do
    open_mix_at(390)

    x, y = page.evaluate_script(<<~JS)
      (() => {
        const row = #{level_row("code_review", "senior")};
        row.scrollIntoView({ block: "center" });
        const box = row.getBoundingClientRect();
        return [box.right - 4, box.top + box.height / 2];
      })()
    JS
    inside = page.evaluate_script("document.elementFromPoint(#{x}, #{y}).closest('label') === #{level_row("code_review", "senior")}")
    page.driver.with_playwright_page { |pw| pw.mouse.click(x, y) }

    expect(inside).to be(true)
    expect(page).to have_checked_field("level-code_review", with: "senior", visible: :all)
    wait_for { user.reload.section_kind_levels["code_review"] == "senior" }
  end

  it "marks the chosen row by border and weight, not color alone" do
    open_mix_at(390)

    style = ->(value, property) { page.evaluate_script("getComputedStyle(#{level_row("code_review", value)})[#{property.to_json}]") }

    expect(style.call("", "borderTopWidth")).to eq("2px")
    expect(style.call("", "fontWeight")).to eq("600")
    expect(style.call("junior", "borderTopWidth")).to eq("1px")
    expect(style.call("junior", "fontWeight")).to eq("400")
  end

  it "wraps a long option label inside its row at 320px with the largest text" do
    user.update!(display_preferences: { "text_size" => "140" })
    open_mix_at(320)

    geometry = page.evaluate_script(<<~JS)
      (() => {
        const row = #{level_row("code_review", "")}.getBoundingClientRect();
        const text = #{level_row("code_review", "")}.querySelector("span").getBoundingClientRect();
        return [row.height, text.right, row.right, document.documentElement.scrollWidth];
      })()
    JS

    expect(geometry[0]).to be > 48
    expect(geometry[1]).to be <= geometry[2]
    expect(geometry[3]).to eq(320)
  end

  it "mutes an excluded kind's rows without stacking opacity" do
    open_mix_at(390)
    find("#exclude-challenge").click
    wait_for { user.reload.excluded_section_kinds.include?("challenge") }

    rows = page.evaluate_script("Array.from(document.querySelectorAll(\".mix-difficulty[data-kind='challenge'] .mix-level\")).map(r => [getComputedStyle(r).color, getComputedStyle(r).opacity])")
    lock = page.evaluate_script("(() => { const box = document.querySelector('#lock-challenge'); return [getComputedStyle(box.closest('.switch-row')).color, getComputedStyle(box).opacity]; })()")

    expect(rows).not_to be_empty
    expect(rows.map(&:first)).to all(eq(computed_color("--muted")))
    expect(rows.map(&:last)).to all(eq("1"))
    expect(lock).to eq([ computed_color("--muted"), "0.4" ])
  end

  it "moves the checked level with the arrow keys and saves it" do
    open_mix_at(390)
    page.execute_script("document.querySelector(\"input[name='level-code_review'][value='']\").focus()")
    page.driver.with_playwright_page { |pw| pw.keyboard.press("ArrowDown") }

    expect(page).to have_checked_field("level-code_review", with: "junior", visible: :all)
    wait_for { user.reload.section_kind_levels["code_review"] == "junior" }
  end

  it "saves a slider's stop and shows its label" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click
    find("#weight-challenge").set(0)

    expect(find("#weight-label-challenge")).to have_text("Much less")
    expect(weights_after_save({ "challenge" => 0.25 })).to eq("challenge" => 0.25)
  end

  it "announces a moved slider's stop word as its value" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click
    find("#weight-challenge").set(0)

    expect(page).to have_css('#weight-challenge[aria-valuetext="Much less"]')
  end

  it "gives every skip switch row 48px and a 44px switch" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    heights = page.evaluate_script("Array.from(document.querySelectorAll('.mix-exclude-box')).map(box => box.closest('.switch-row').getBoundingClientRect().height)")
    widths = page.evaluate_script("Array.from(document.querySelectorAll('.mix-exclude-box')).map(box => box.offsetWidth)")
    name_and_stop = page.evaluate_script(<<~JS)
      (() => {
        const name = document.querySelector("label[for='weight-challenge']").getBoundingClientRect();
        const stop = document.querySelector("#weight-label-challenge").getBoundingClientRect();
        return [name.top, stop.top, name.right, stop.right];
      })()
    JS

    expect(heights.size).to be > 1
    expect(heights).to all(be >= 48)
    expect(widths).to all(be >= 44)
    expect(name_and_stop[1]).to be_within(1).of(name_and_stop[0])
    expect(name_and_stop[3]).to be >= name_and_stop[2]
  end

  it "refuses a save from a page whose controls predate another save, and re-syncs the controls" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.update!(excluded_section_kinds: [ "parsons_problem" ])

    find("#weight-challenge").set(0)

    expect(page).to have_css("#save-status", text: /changed in another tab/i)
    expect(user.reload.section_kind_weights).to eq({})
    expect(find("#exclude-parsons_problem")).to be_checked
  end

  it "reloads instead of re-syncing when another tab swapped a daily kind, so the new controls are on the page" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script("window.renderedBeforeSwap = true")

    user.update!(daily_section_kinds: %w[code_review challenge])
    find("#weight-architecture").set(0)

    expect(page).to have_no_css("#weight-challenge")
    expect(page.evaluate_script("window.renderedBeforeSwap === undefined")).to be(true)
    expect(user.reload.section_kind_weights).to eq({})
  end

  it "sends a skill level change queued behind a mix save before reloading for another tab's swap" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      window.renderedBeforeSwap = true;
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes('"skill_level"')) return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 500));
        if (!body.includes('"layout"')) return send(url, options);
        return new Promise((resolve) => { window.releaseMixSave = () => resolve(send(url, options)); });
      };
    JS

    find("#weight-architecture").set(0)
    wait_for { page.evaluate_script("typeof window.releaseMixSave === 'function'") }
    user.update!(daily_section_kinds: %w[code_review challenge])
    level = (User::SKILL_LEVELS - [ user.skill_level ]).first
    find("#skill-level", visible: :all).select(I18n.t("exercise_mix.levels.#{level}"), visible: :all)
    page.execute_script("window.releaseMixSave()")

    expect(page).to have_no_css("#weight-challenge")
    expect(page.evaluate_script("window.renderedBeforeSwap === undefined")).to be(true)
    expect(user.reload.skill_level).to eq(level)
  end

  it "keeps the page and the unsaved skill level when the save queued behind the swapped-layout reply fails, and through a repeated conflict" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      window.renderedBeforeSwap = true;
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes('"skill_level"')) return new Promise((resolve) => setTimeout(() => resolve(new Response("", { status: 503 })), 500));
        if (!body.includes('"layout"')) return send(url, options);
        return new Promise((resolve) => { window.releaseMixSave = () => resolve(send(url, options)); });
      };
    JS

    find("#weight-architecture").set(0)
    wait_for { page.evaluate_script("typeof window.releaseMixSave === 'function'") }
    user.update!(daily_section_kinds: %w[code_review challenge])
    stored = user.skill_level
    level = (User::SKILL_LEVELS - [ stored ]).first
    find("#skill-level", visible: :all).select(I18n.t("exercise_mix.levels.#{level}"), visible: :all)
    page.execute_script("window.releaseMixSave()")

    expect(page).to have_css("#save-status", text: I18n.t("exercise_mix.layout_stranded"))
    expect(page.evaluate_script("window.renderedBeforeSwap")).to be(true)
    expect(find("#skill-level", visible: :all).value).to eq(level)
    expect(user.reload.skill_level).to eq(stored)

    page.execute_script("window.releaseMixSave = null; window.CodeGymSaveStatus.clear('exercise_mix')")
    find("#weight-architecture").set(4)
    wait_for { page.evaluate_script("typeof window.releaseMixSave === 'function'") }
    page.execute_script("window.releaseMixSave()")

    expect(page).to have_css("#save-status", text: I18n.t("exercise_mix.layout_stranded"))
    expect(page.evaluate_script("window.renderedBeforeSwap")).to be(true)
    expect(find("#skill-level", visible: :all).value).to eq(level)
  end

  it "keeps the page when another control's save failed before the swapped-layout reply arrived" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      window.renderedBeforeSwap = true;
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes('"time_zone"')) return Promise.resolve(new Response("", { status: 503 }));
        return send(url, options);
      };
    JS

    find("#tz-select", visible: :all).select(I18n.t("api_keys.edit.time_zones.hawaii"), visible: :all)
    expect(page).to have_css("#save-status:not([hidden])")
    user.update!(daily_section_kinds: %w[code_review challenge])
    find("#weight-architecture").set(0)

    expect(page).to have_css("#save-status", text: I18n.t("exercise_mix.layout_stranded"))
    expect(page.evaluate_script("window.renderedBeforeSwap")).to be(true)
    expect(find("#tz-select", visible: :all).value).to eq("Pacific/Honolulu")
  end

  it "leaves the reload to the user when a save queued behind the swapped-layout reply never finishes" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      window.renderedBeforeSwap = true;
      const send = window.fetch;
      const wait = window.setTimeout;
      window.setTimeout = (callback, delay, ...rest) => wait(callback, delay === 200 ? 0 : delay, ...rest);
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes('"skill_level"')) return new Promise(() => {});
        if (!body.includes('"layout"')) return send(url, options);
        return new Promise((resolve) => { window.releaseMixSave = () => resolve(send(url, options)); });
      };
    JS

    find("#weight-architecture").set(0)
    wait_for { page.evaluate_script("typeof window.releaseMixSave === 'function'") }
    user.update!(daily_section_kinds: %w[code_review challenge])
    find("#skill-level", visible: :all).select(I18n.t("exercise_mix.levels.#{(User::SKILL_LEVELS - [ user.skill_level ]).first}"), visible: :all)
    page.execute_script("window.releaseMixSave()")

    expect(page).to have_css("#save-status", text: I18n.t("exercise_mix.layout_stranded"))
    expect(page.evaluate_script("window.renderedBeforeSwap")).to be(true)
  end

  it "keeps a daily kind's difficulty controls enabled after a re-sync, though it was excluded before it became daily" do
    user.update!(excluded_section_kinds: %w[challenge])
    user.update!(daily_section_kinds: %w[code_review challenge])
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.update!(section_kind_levels: { "pattern" => "senior" })
    find("#weight-architecture").set(0)

    expect(page).to have_css("#save-status", text: /changed in another tab/i)
    expect(page).to have_no_css("fieldset.mix-difficulty[data-kind='challenge'] input[type=radio]:disabled")
    expect(user.reload.excluded_section_kinds).to eq(%w[challenge])
  end

  # The debounce is 400ms, so a slow save is still in flight when the next posts; unchained, the second would be refused.
  it "does not refuse a second save issued while this tab's first is in flight" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    hold_profile_saves(2500)

    find("#weight-challenge").set(0)
    sleep 0.8
    find("#weight-challenge").set(4)

    expect(weights_after_save({ "challenge" => 4.0 })).to eq("challenge" => 4.0)
  end

  # Delay the response handling, not the request: delaying requests would reorder arrivals and stop reproducing this.
  def hold_profile_saves(millis)
    page.execute_script(<<~JS)
      (function () {
        const original = window.fetch;
        window.fetch = function (url, options) {
          const response = original.apply(this, arguments);
          if (String(url).indexOf("/profile") === -1) return response;

          return response.then((r) => new Promise((resolve) => setTimeout(() => resolve(r), #{millis})));
        };
      })();
    JS
  end

  it "locks the last remaining kind in a group rather than letting a slot empty" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click

    excluded = ExerciseSection.fourths.first(ExerciseSection.fourths.size - 1)
    excluded.each { |kind| find("#exclude-#{kind.key}").click }

    last = ExerciseSection.fourths.last

    expect(find("#exclude-#{last.key}")).to be_disabled
    row = page.evaluate_script("(() => { const s = getComputedStyle(document.querySelector('#exclude-#{last.key}').closest('.switch-row')); return [s.color, s.opacity]; })()")
    expect(row).to eq([ computed_color("--muted"), "1" ])
    expect(page).to have_text("At least one section in this group has to stay in rotation.")
    # lockLastInGroup runs whether or not the click saved, so without this the example passes with autosave deleted.
    expect(exclusions_after_save(excluded.map(&:key))).to contain_exactly(*excluded.map(&:key))
  end

  def difficulty_after_save(levels, locked)
    wait_for { user.reload.section_kind_levels == levels && user.locked_section_kinds.sort == locked.sort }
    [ user.reload.section_kind_levels, user.locked_section_kinds ]
  end

  it "gives fixed sections difficulty controls and no slider or exclude" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    within(".mix-difficulty[data-kind='code_review']") do
      expect(page).to have_field("level-code_review", type: "radio", count: KindDifficulty::LEVELS.size + 1)
      expect(page).to have_css("label.mix-level", count: KindDifficulty::LEVELS.size + 1)
    end
    expect(page).not_to have_css("#weight-code_review")
    expect(page).not_to have_css("#exclude-code_review")
  end

  it "keeps the same open document while targets are added and cleared" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script("window.mixEditingMarker = true")

    changes = [
      [ "pattern", "junior", { "pattern" => "junior" } ],
      [ "architecture", "senior", { "pattern" => "junior", "architecture" => "senior" } ],
      [ "pattern", "", { "architecture" => "senior" } ],
      [ "architecture", "", {} ]
    ]
    changes.each do |kind, level, expected|
      find(".mix-difficulty[data-kind='#{kind}'] input[value='#{level}']").click
      expect(difficulty_after_save(expected, [])).to eq([ expected, [] ])
      count = LadderCoverage.for(user).gaps.size
      if count.positive?
        expect(page).to have_button(I18n.t("exercise_mix.ladders_button", count: count), disabled: false)
      else
        expect(page).to have_no_css(".mix-ladders", visible: true)
      end
      expect(page.evaluate_script("window.mixEditingMarker")).to be(true)
      expect(find("#exercise-mix")).to match_css("[open]")
    end
  end

  it "saves a level and a lock, and keeps them across a manual reload" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    expect(find("#lock-code_review")).to be_disabled
    find(".mix-difficulty[data-kind='code_review'] input[value='principal_engineer']").click
    expect(find("#lock-code_review")).not_to be_disabled
    find("#lock-code_review").click

    expect(difficulty_after_save({ "code_review" => "principal_engineer" }, [ "code_review" ]))
      .to eq([ { "code_review" => "principal_engineer" }, [ "code_review" ] ])

    visit setup_path
    find("#exercise-mix summary").click
    expect(find(".mix-difficulty[data-kind='code_review'] input[value='principal_engineer']")).to be_checked
    expect(find("#lock-code_review")).to be_checked
  end

  it "clears the lock when the level goes back to the default, and hides coverage" do
    user.update!(section_kind_levels: { "challenge" => "senior" }, locked_section_kinds: [ "challenge" ])
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    expect(find(".mix-difficulty[data-kind='challenge'] .mix-coverage", visible: :all)).to be_visible
    find(".mix-difficulty[data-kind='challenge'] input[value='']").click

    expect(find("#lock-challenge")).not_to be_checked
    expect(find("#lock-challenge")).to be_disabled
    expect(page).to have_css(".mix-difficulty[data-kind='challenge'] .mix-coverage", visible: :hidden)
    expect(difficulty_after_save({}, [])).to eq([ {}, [] ])
  end

  it "shows coverage as soon as a target is picked, without a reload" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    find(".mix-difficulty[data-kind='pattern'] input[value='junior']").click

    expect(find(".mix-difficulty[data-kind='pattern'] .mix-coverage")).to have_text(/of \d+ concepts have AI difficulty guidance/)
  end

  it "offers the optional AI guidance control before any target, and keeps it after one without closing the settings" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    expect(page).to have_css(".mix-ladders", visible: true)

    find(".mix-difficulty[data-kind='pattern'] input[value='junior']").click

    expect(difficulty_after_save({ "pattern" => "junior" }, [])).to eq([ { "pattern" => "junior" }, [] ])
    count = LadderCoverage.for(user.reload).gaps.size
    expect(page).to have_button(I18n.t("exercise_mix.ladders_button", count: count), disabled: false)
    expect(find("#exercise-mix")).to match_css("[open]")
    expect(page).to have_content(I18n.t("exercise_mix.ladders_explanation"))
  end

  it "restores levels and locks from the server after a refused save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.update!(section_kind_levels: { "pattern" => "senior" }, locked_section_kinds: [ "pattern" ])

    find(".mix-difficulty[data-kind='code_review'] input[value='junior']").click

    expect(page).to have_css("#save-status", text: /changed in another tab/i)
    expect(find(".mix-difficulty[data-kind='pattern'] input[value='senior']")).to be_checked
    expect(find("#lock-pattern")).to be_checked
    expect(find(".mix-difficulty[data-kind='code_review'] input[value='']")).to be_checked
    count = LadderCoverage.for(user.reload).gaps.size
    expect(page).to have_button(I18n.t("exercise_mix.ladders_button", count: count), disabled: false)
  end

  def defer_mix_responses(fail_second: false)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      const originalTimeout = window.setTimeout;
      window.mixResponses = [];
      window.mixDebounces = 0;
      let requests = 0;
      window.setTimeout = function (callback, delay, ...args) {
        return originalTimeout(() => {
          if (delay === 400) window.mixDebounces++;
          callback(...args);
        }, delay);
      };
      window.fetch = function (url, options) {
        if (!String(url).includes("/profile")) return originalFetch(url, options);
        requests++;
        const response = #{fail_second} && requests === 2
          ? Promise.resolve(new Response("", { status: 503 }))
          : originalFetch(url, options);
        return response.then((result) => new Promise((resolve) => {
          window.mixResponses.push(() => resolve(result));
        }));
      };
    JS
  end

  def wait_for_mix_responses(count)
    wait_for { page.evaluate_script("window.mixResponses?.length") == count }
    expect(page.evaluate_script("window.mixResponses?.length")).to eq(count)
  end

  [ "pending", "queued" ].each do |phase|
    it "flushes a #{phase} lock and weight edit before enabling guidance preparation" do
      visit_as(user)
      visit setup_path
      find("#exercise-mix summary").click
      defer_mix_responses

      find(".mix-difficulty[data-kind='code_review'] input[value='junior']").click
      wait_for_mix_responses(1)
      page.execute_script(<<~JS)
        document.querySelector("#lock-code_review").click();
        const slider = document.querySelector("#weight-challenge");
        slider.value = 0;
        slider.dispatchEvent(new Event("input"));
        #{'window.mixResponses[0]();' if phase == "pending"}
      JS
      if phase == "queued"
        wait_for { page.evaluate_script("window.mixDebounces") == 2 }
        expect(page.evaluate_script("window.mixDebounces")).to eq(2)
        page.execute_script("window.mixResponses[0]()")
      end

      wait_for_mix_responses(2)
      expect(page).to have_button("prepare-ladders", disabled: true)
      page.execute_script("window.mixResponses[1]()")

      expect(page).to have_css(".mix-ladders", visible: true)
      expect(page).to have_button("prepare-ladders", disabled: false)
      expect(page.evaluate_script("window.mixResponses.length")).to eq(2)
      expect(find("#exercise-mix")).to match_css("[open]")
      expect(find("#lock-code_review")).to be_checked
      expect(find("#weight-label-challenge")).to have_text("Much less")
      expect(user.reload.locked_section_kinds).to eq([ "code_review" ])
      expect(user.section_kind_weights).to eq("challenge" => 0.25)
    end
  end

  it "keeps a failed pending edit visible until a later successful save updates guidance preparation" do
    user.update!(section_kind_levels: { "pattern" => "junior" })
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    defer_mix_responses(fail_second: true)

    find(".mix-difficulty[data-kind='code_review'] input[value='junior']").click
    wait_for_mix_responses(1)
    page.execute_script('document.querySelector("#lock-code_review").click(); window.mixResponses[0]()')
    wait_for_mix_responses(2)
    page.execute_script("window.mixResponses[1]()")

    expect(page).to have_css("#save-status", visible: true)
    expect(find("#lock-code_review")).to be_checked
    expect(user.reload.locked_section_kinds).to eq([])
    expect(page).to have_button("prepare-ladders", disabled: true)

    find("#weight-challenge").set(0)
    wait_for_mix_responses(3)
    page.execute_script("window.mixResponses[2]()")

    expect(page).to have_css(".mix-ladders", visible: true)
    expect(page).to have_button("prepare-ladders", disabled: false)
    expect(page.evaluate_script("window.mixResponses.length")).to eq(3)
    expect(user.reload.locked_section_kinds).to eq([ "code_review" ])
    expect(user.section_kind_weights).to eq("challenge" => 0.25)
  end

  it "gives the slider a 44px input, a 6px track and a 28px thumb" do
    open_mix_at(390)

    styles = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("#weight-challenge");
        const css = getComputedStyle(el);
        return {
          height: el.getBoundingClientRect().height,
          track: parseFloat(getComputedStyle(el, "::-webkit-slider-runnable-track").height),
          thumb: parseFloat(getComputedStyle(el, "::-webkit-slider-thumb").width),
          paddingLeft: css.paddingLeft,
          borderStyle: css.borderStyle
        };
      })()
    JS

    expect(styles["height"]).to be >= 44
    expect(styles["track"]).to be >= 6
    expect(styles["thumb"]).to be >= 28
    expect(styles["paddingLeft"]).to eq("0px")
    expect(styles["borderStyle"]).to eq("none")
  end

  it "falls back to the native slider in forced colors" do
    open_mix_at(390)
    set_forced_colors("active")

    begin
      expect(page.evaluate_script('matchMedia("(forced-colors: active)").matches')).to be(true)
      result = page.evaluate_script(<<~JS)
        (() => {
          const probe = document.createElement("div");
          probe.style.cssText = "border: 2px solid Highlight";
          document.body.appendChild(probe);
          const highlight = getComputedStyle(probe).borderTopColor;
          probe.remove();
          const checked = document.querySelector(".mix-level:has(input:checked)");
          return {
            appearance: getComputedStyle(document.querySelector("#weight-challenge")).appearance,
            checked: getComputedStyle(checked).borderTopColor,
            highlight: highlight
          };
        })()
      JS

      expect(result["appearance"]).to eq("auto")
      expect(result["checked"]).to eq(result["highlight"])
    ensure
      set_forced_colors("none")
    end
    expect(page.evaluate_script('matchMedia("(forced-colors: active)").matches')).to be(false)
  end

  it "gives About summaries 44px in Exercise mix" do
    open_mix_at(390)
    heights = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("#exercise-mix .kind-about > summary")].map((s) => s.getBoundingClientRect().height)
    JS
    expect(heights).not_to be_empty
    expect(heights).to all(be >= 44)
  end

  it "leaves the answer form's About summaries at the layout's height" do
    visit_with_todays_set(user)
    min_height = page.evaluate_script('getComputedStyle(document.querySelector(".kind-about > summary")).minHeight')
    expect(min_height).to eq("24px")
  end
end
