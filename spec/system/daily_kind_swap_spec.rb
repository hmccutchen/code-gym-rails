require "rails_helper"

RSpec.describe "Swapping a daily section kind", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    visit_with_todays_set(user)
    wait_for_js
  end

  def panel(place) = find("#daily-kind-swap-panel-#{place}")

  def sheet(place) = "#daily-kind-#{place}-sheet"

  def primary(place) = find("#{sheet(place)} [data-daily-kind-swap-target='confirm']")

  def press(key) = page.driver.with_playwright_page { |pw| pw.keyboard.press(key) }

  def focused(script) = page.evaluate_script("document.activeElement.#{script}")

  def trigger_focused?
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    loop do
      return true if page.evaluate_script("document.activeElement.classList.contains('daily-kind-trigger')")
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def open_sheet(place)
    within(panel(place)) { find("button.daily-kind-trigger").click }
    expect(page).to have_css("#{sheet(place)}[open]")
  end

  def confirm_swap(place, kind)
    open_sheet(place)
    find("#daily-kind-#{place}-#{kind}").click
    primary(place).click
  end

  def finish_saved(place)
    within(sheet(place)) { click_button "Done" }
    expect(page).to have_no_css("#{sheet(place)}[open]")
  end

  def close_sheet(place)
    press("Escape")
    expect(page).to have_no_css("#{sheet(place)}[open]")
  end

  # Stands in for Chrome closing a saving sheet on a second Escape, whose activation rule varies between builds.
  def leave_sheet_saving(place, and_run: nil)
    expect(page).to have_css("#{sheet(place)} [data-daily-kind-swap-target='status']", text: I18n.t("daily_kinds.picker.saving"))
    page.execute_script("document.querySelector(#{sheet(place).to_json}).close(); #{and_run}")
    expect(page).to have_no_css("#{sheet(place)}[open]")
  end

  it "opens the sheet with the current kind checked and the other daily kind disabled under its badge" do
    open_sheet(0)

    expect(find("#daily-kind-0-code_review")).to be_checked
    expect(page).to have_css("label[data-kind='code_review'] .daily-kind-badge-now", text: "Now")
    expect(find("#daily-kind-0-design_comparison")).to be_disabled
    expect(page).to have_css("label[data-kind='design_comparison'] .daily-kind-badge", text: "Already daily")
    expect(page).to have_css("#daily-kind-0-design_comparison-short", text: SectionKindGuide.for("design_comparison")[:short])
    expect(page).to have_css(sheet(0), text: I18n.t("daily_kinds.picker.next_set"))
    expect(page).to have_css("#daily-kind-0-title", text: I18n.t("daily_kinds.picker.title"))
    expect(primary(0)).to be_disabled
    expect(primary(0).text).to eq("Swap")
  end

  it "points each available radio at its summary line, example and consequence block, and shows the chosen kind's" do
    open_sheet(0)
    available = all("#{sheet(0)} input[data-state='available']")

    expect(available.size).to be > 5
    available.each do |radio|
      expect(radio["aria-describedby"].split).to eq([ "#{radio[:id]}-short", "#{radio[:id]}-guide", "#{radio[:id]}-consequences" ])
    end
    expect(page).to have_css("#daily-kind-0-challenge-guide", visible: :hidden)
    expect(page).to have_css(".daily-kind-sheet-footer #daily-kind-0-challenge-consequences", visible: :all)

    find("#daily-kind-0-challenge").click
    expect(page).to have_css("#daily-kind-0-challenge-guide", visible: :visible, text: SectionKindGuide.for("challenge")[:example])
    expect(page).to have_css("#daily-kind-0-code_review-guide", visible: :hidden)
    expect(page).to have_css("#daily-kind-0-challenge-consequences", visible: :visible)
    expect(primary(0)).not_to be_disabled
    expect(primary(0)["aria-describedby"]).to eq("daily-kind-0-challenge-consequences")
  end

  it "names the checked kind on the primary button, and goes back to Swap on the current kind" do
    open_sheet(0)

    find("#daily-kind-0-challenge").click
    expect(primary(0).text).to eq("Swap to Coding Challenge")
    find("#daily-kind-0-architecture").click
    expect(primary(0).text).to eq("Swap to Architecture Decision")
    find("#daily-kind-0-code_review").click
    expect(primary(0).text).to eq("Swap")
    expect(primary(0)).to be_disabled
  end

  it "saves a swap, shows the saved state with the offer for today, and refreshes both sheets with the new version" do
    version = panel(0)["data-version"]
    confirm_swap(0, "challenge")

    expect(page).to have_css("#{sheet(0)}[open] .daily-kind-saved", text: I18n.t("daily_kinds.swap.saved"))
    expect(page).to have_css("#{sheet(0)} .daily-kind-saved", text: I18n.t("daily_kinds.swap.want_it_today"))
    expect(page).to have_link(I18n.t("daily_kinds.picker.generate_link"))
    expect(page).to have_no_css("#{sheet(0)} .daily-kind-picker", visible: :visible)
    expect(focused("textContent")).to eq("Done")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
    expect(panel(0)["data-version"]).not_to eq(version)
    expect(panel(1)["data-version"]).to eq(panel(0)["data-version"])
    expect(panel(0)["data-current"]).to eq("challenge")

    finish_saved(0)
    expect(trigger_focused?).to be(true)
    expect(panel(0)).to have_css(".daily-kind-next", text: "Your next set uses Coding Challenge here.")
    open_sheet(1)
    expect(find("#daily-kind-1-challenge")).to be_disabled
  end

  it "closes the saved sheet from its link and moves focus to the existing Generate new set button" do
    confirm_swap(0, "challenge")
    click_link I18n.t("daily_kinds.picker.generate_link")

    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(page.evaluate_script("document.activeElement === document.querySelector('.regenerate-row form button')")).to be(true)
  end

  it "takes two swaps in a row without a reload" do
    page.execute_script("window.swapPage = true")
    confirm_swap(0, "challenge")
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    finish_saved(0)

    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
    expect(page.evaluate_script("window.swapPage")).to be(true)
  end

  it "shows the stale message, keeps the sheet open on the pair another tab stored, and saves on the next try" do
    user.update!(daily_section_kinds: %w[pattern design_comparison])
    confirm_swap(0, "architecture")

    expect(page).to have_css("#save-status", text: I18n.t("daily_kinds.swap.refused.stale"))
    expect(page).to have_css("#{sheet(0)} .daily-kind-error", text: I18n.t("daily_kinds.swap.refused.stale"))
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='pattern']")
    expect(page).to have_css("#{sheet(0)}[open]")
    expect(page.evaluate_script("document.activeElement.id")).to eq("daily-kind-0-pattern")
    expect(user.reload.daily_section_kinds).to eq(%w[pattern design_comparison])

    find("#daily-kind-0-architecture").click
    primary(0).click
    expect(page).to have_css("#{sheet(0)} .daily-kind-saved", text: I18n.t("daily_kinds.swap.saved"))
    expect(user.reload.daily_section_kinds).to eq(%w[architecture design_comparison])
  end

  it "shows a refusal in the sheet and the banner, and keeps the sheet open with focus on the primary" do
    open_sheet(0)
    find("#daily-kind-0-challenge").click
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.includes("/daily_kinds/")
        ? Promise.resolve(new Response(JSON.stringify({ status: "invalid", error: "That swap couldn't be saved." }), { status: 422, headers: { "Content-Type": "application/json" } }))
        : originalFetch(url, options);
    JS
    primary(0).click

    expect(page).to have_css("#{sheet(0)} .daily-kind-error[role='status']", text: "That swap couldn't be saved.")
    expect(page).to have_css("#save-status", text: "That swap couldn't be saved.")
    expect(page).to have_css("#{sheet(0)}[open]")
    expect(focused("textContent")).to eq("Swap to Coding Challenge")
    expect(primary(0)["aria-describedby"].split).to eq(%w[daily-kind-0-challenge-consequences daily-kind-0-error])
  end

  def hold_swap_replies
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.heldSwaps = [];
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.heldSwaps.push(JSON.parse(options.body));
        return new Promise((resolve) => { window.releaseSwap = () => resolve(originalFetch(url, options)); });
      };
    JS
  end

  def release_swap
    wait_for_js_condition("window.releaseSwap")
    page.execute_script("const release = window.releaseSwap; window.releaseSwap = null; release()")
  end

  it "sends a second card's swap only after the first one's reply, with the version that reply left" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "pattern")

    wait_for_js_condition("window.heldSwaps.length === 1")
    release_swap
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    wait_for_js_condition("window.heldSwaps.length === 2")
    first, second = page.evaluate_script("window.heldSwaps")
    expect(second["section_kind_preferences_version"]).not_to eq(first["section_kind_preferences_version"])

    release_swap
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
    expect(page).to have_no_css("#save-status", visible: :visible)
  end

  it "reopens a queued card refused after the first card's swap, focused on a control it can use" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "challenge")
    release_swap
    wait_for_js_condition("window.heldSwaps.length === 2")
    release_swap

    expect(page).to have_css("#save-status", text: I18n.t("daily_kinds.swap.refused.already_daily"))
    expect(page).to have_css("#{sheet(1)} .daily-kind-error", text: I18n.t("daily_kinds.swap.refused.already_daily"))
    expect(page).to have_css("#{sheet(1)}[open]")
    expect(find("#daily-kind-1-challenge")).to be_disabled
    expect(focused("disabled")).to be(false)
    expect(focused("id")).to eq("daily-kind-1-design_comparison")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end

  it "reopens a queued card whose swap failed in transit with its choice kept and the primary focused" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.swapCalls = 0;
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.swapCalls += 1;
        if (window.swapCalls === 1) return new Promise((resolve) => { window.releaseSwap = () => resolve(originalFetch(url, options)); });
        if (window.swapCalls === 2) return Promise.resolve(new Response("unavailable", { status: 503 }));
        return originalFetch(url, options);
      };
    JS
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "pattern")
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_css("#{sheet(1)}[open]")
    expect(find("#daily-kind-1-pattern")).to be_checked
    expect(focused("textContent")).to eq("Swap to Pattern of the Month")
    expect(focused("disabled")).to be(false)

    primary(1).click
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
  end

  it "keeps one card's failure showing after the other card saves, until that card saves" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.swapCalls = 0;
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.swapCalls += 1;
        if (window.swapCalls > 1) return originalFetch(url, options);
        return new Promise((resolve) => { window.releaseSwap = () => resolve(new Response("unavailable", { status: 503 })); });
      };
    JS
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "pattern")
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_css("#save-status", visible: :visible)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
    expect(page).to have_no_css("#{sheet(0)}[open]")

    finish_saved(1)
    open_sheet(0)
    expect(find("#daily-kind-0-challenge")).to be_checked
    expect(page).to have_css("#{sheet(0)} .daily-kind-error", text: I18n.t("save_status.generic"))
    expect(primary(0)["aria-describedby"].split).to include("daily-kind-0-error")
    primary(0).click
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_no_css("#save-status", visible: :visible)
  end

  def submit_one_answer
    page.execute_script("window.swapPage = true")
    fill_in_answer("code_review", "The answer that is submitted while both swaps are still queued.")
    rate_section("code_review")
    click_button "Submit answers"
    wait_for { user.daily_responses.reload.first&.submitted? }
    expect(user.daily_responses.sole).to be_submitted
  end

  it "waits for queued swaps to save before a submit leaves the page" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "pattern")
    leave_sheet_saving(1)
    submit_one_answer

    expect(page.evaluate_script("window.swapPage")).to be(true)
    release_swap
    wait_for_js_condition("window.heldSwaps.length === 2")
    release_swap

    expect(page).to have_content("✓ Submitted")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
  end

  it "stays on the page with the failure showing when a queued swap fails during a submit" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.swapCalls = 0;
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.swapCalls += 1;
        if (window.swapCalls === 2) return Promise.resolve(new Response("unavailable", { status: 503 }));
        return new Promise((resolve) => { window.releaseSwap = () => resolve(originalFetch(url, options)); });
      };
    JS
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "pattern")
    leave_sheet_saving(1)
    submit_one_answer
    release_swap

    expect_held
    sleep 1.5
    expect(page.evaluate_script("window.swapPage")).to be(true)
    expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(false)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])

    expect(page).to have_no_css("#{sheet(1)}[open]")
    open_sheet(1)
    expect(find("#daily-kind-1-pattern")).to be_checked
    expect(page).to have_css("#{sheet(1)} .daily-kind-error", text: I18n.t("save_status.generic"))
    primary(1).click
    release_swap
    expect(page).to have_content("✓ Submitted")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
  end

  def expect_held
    expect(page).to have_css("#save-status", visible: :visible)
    expect(page).to have_css("#leave-held", text: I18n.t("dashboard.exercise.leave_held"))
    expect(page).to have_css("#leave-held button", text: I18n.t("dashboard.exercise.reload_now"))
    expect(page).to have_button("Submit answers", disabled: true)
  end

  def fail_every_swap
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.includes("/daily_kinds/")
        ? Promise.resolve(new Response("unavailable", { status: 503 }))
        : originalFetch(url, options);
    JS
  end

  it "keeps answers read-only while a submit is held, so no edit is silently dropped" do
    fail_every_swap
    confirm_swap(1, "pattern")
    close_sheet(1)
    submit_one_answer
    expect_held

    area = find(%(textarea[data-field="code_review"]))
    before = area.value
    page.execute_script(%(document.querySelector('textarea[data-field="code_review"]').focus()))
    page.driver.with_playwright_page { |pw| pw.keyboard.type(" more") }
    expect(area.value).to eq(before)
    expect(page.evaluate_script(%(document.activeElement.matches('textarea[data-field="code_review"]')))).to be(false)
    expect(page.evaluate_script(%(Boolean(document.querySelector('button[data-rating-for="code_review"]').closest("[inert]"))))).to be(true)
    expect(page.evaluate_script("Boolean(document.querySelector('.daily-kind-swap').closest('[inert]'))")).to be(false)
  end

  def fail_first_swap
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.swapCalls = 0;
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.swapCalls += 1;
        if (window.swapCalls === 1) return Promise.resolve(new Response("unavailable", { status: 503 }));
        return originalFetch(url, options);
      };
    JS
    confirm_swap(1, "pattern")
    expect(page).to have_css("#save-status", visible: :visible)
    close_sheet(1)
    page.execute_script("window.swapPage = true")
  end

  def type_an_answer
    fill_in_answer("code_review", "An edit typed after another tab changed the set on the server.")
    sleep 1.5
  end

  it "does not reload over a failed swap when an autosave finds the set submitted in another tab" do
    fail_first_swap
    response = DailyResponse.create!(user: user, daily_exercise: user.daily_exercises.sole, date: Date.current, submitted_at: Time.current,
                                     answers: { "code_review" => "Submitted from another tab with enough detail." },
                                     section_ratings: { "code_review" => "right_level" })
    type_an_answer

    expect(response.reload).to be_submitted
    expect(page.evaluate_script("window.swapPage")).to be(true)
    expect_held_autosave
    retry_swap_and_expect_reload
  end

  def expect_held_autosave
    expect(page).to have_css("#save-status", visible: :visible)
    expect(page).to have_css("#leave-held button", text: I18n.t("dashboard.exercise.reload_now"))
  end

  def retry_swap_and_expect_reload
    confirm_swap(1, "pattern")
    wait_for_js_condition("window.swapPage === undefined", timeout: 8)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
  end

  it "freezes the answers as soon as an autosave waits on a swap, and reloads once the swap lands" do
    hold_swap_replies
    confirm_swap(1, "pattern")
    leave_sheet_saving(1)
    page.execute_script("window.swapPage = true")
    DailyResponse.create!(user: user, daily_exercise: user.daily_exercises.sole, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "Submitted from another tab with enough detail." },
                          section_ratings: { "code_review" => "right_level" })
    type_an_answer

    area = find(%(textarea[data-field="code_review"]))
    before = area.value
    page.execute_script(%(document.querySelector('textarea[data-field="code_review"]').focus()))
    page.driver.with_playwright_page { |pw| pw.keyboard.type(" more") }
    expect(area.value).to eq(before)
    expect(page.evaluate_script(%(Boolean(document.querySelector('button[data-rating-for="code_review"]').closest("[inert]"))))).to be(true)
    expect(page.evaluate_script("Boolean(document.querySelector('.daily-kind-swap').closest('[inert]'))")).to be(false)
    expect(page.evaluate_script("window.swapPage")).to be(true)

    release_swap
    wait_for_js_condition("window.swapPage === undefined", timeout: 8)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
  end

  it "lets only the review handoff run when an autosave outlasts a held submit" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        const body = options?.body ? JSON.parse(options.body) : {};
        if (!body.response || body.response.submit === "1" || window.releaseAutosave) return originalFetch(url, options);
        return new Promise((resolve) => { window.releaseAutosave = () => resolve(originalFetch(url, options)); });
      };
      HTMLFormElement.prototype.submit = function () { window.reviewHandoffs = (window.reviewHandoffs || 0) + 1; };
    JS
    fill_in_answer("code_review", "The answer an autosave is still carrying when the submit goes out.")
    wait_for_js_condition("window.releaseAutosave")
    submit_one_answer
    expect(page).to have_css("#leave-held")

    page.execute_script("window.releaseAutosave()")
    wait_for_js_condition("window.reviewHandoffs === 1")
    sleep 1.5
    expect(page.evaluate_script("window.swapPage")).to be(true)
    expect(page.evaluate_script("window.reviewHandoffs")).to eq(1)
  end

  def lose_first_swap_reply
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.swapCalls = 0;
      window.fetch = async (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.swapCalls += 1;
        const response = await originalFetch(url, options);
        if (window.swapCalls === 1) throw new TypeError("Response lost after commit");
        return response;
      };
    JS
  end

  it "clears a card's failure when the retry finds its lost swap already stored" do
    lose_first_swap_reply
    confirm_swap(1, "pattern")
    expect(page).to have_css("#save-status", visible: :visible)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])

    expect(focused("textContent")).to eq("Swap to Pattern of the Month")
    primary(1).click
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_no_css("#save-status", visible: :visible)
    expect(page).to have_no_css("#{sheet(1)}[open]")
  end

  it "reloads a finished review even after a stale autosave carried its notice onto the running review" do
    exercise = user.daily_exercises.sole
    exercise.update!(generated_at: Time.current + 1.minute, regenerated_at: Time.current)
    response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                                     reviewing_since: Time.current, answers: { "code_review" => "Submitted with enough detail to count." },
                                     section_ratings: { "code_review" => "right_level" })
    page.execute_script("window.firstPage = true")
    fill_in_answer("code_review", "An edit on the old set that the server refuses as stale.")

    wait_for_js_condition("window.firstPage === undefined", timeout: 8)
    expect(page).to have_css("[data-controller='generating']")
    expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.stale_reloaded"))
    page.execute_script("window.reviewPage = true")
    response.update!(reviewing_since: nil)

    wait_for_js_condition("window.reviewPage === undefined", timeout: 10)
    expect(page).to have_no_css("[data-controller='generating']")
  end

  def record_handoff
    page.execute_script(<<~JS)
      HTMLFormElement.prototype.submit = function () {
        window.handoffs = (window.handoffs || 0) + 1;
        window.swapsInertAtHandoff = Boolean(document.querySelector(".daily-kind-swap").closest("[inert]"));
        window.sheetOpenAtHandoff = Boolean(document.querySelector("dialog.daily-kind-sheet[open]"));
      };
    JS
  end

  it "locks the swap controls again when a held submit resumes into the review" do
    fail_first_swap
    record_handoff
    submit_one_answer
    expect_held

    confirm_swap(1, "pattern")
    wait_for_js_condition("window.handoffs === 1")
    expect(page.evaluate_script("window.swapsInertAtHandoff")).to be(true)
    expect(page.evaluate_script("window.sheetOpenAtHandoff")).to be(false)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
  end

  it "closes an open sheet before a held submit resumes into the review" do
    fail_first_swap
    record_handoff
    submit_one_answer
    expect_held
    open_sheet(0)

    page.execute_script(%(window.CodeGymSaveStatus.clear("daily_kind_swap:/daily_kinds/1")))
    wait_for_js_condition("window.handoffs === 1")
    expect(page.evaluate_script("window.sheetOpenAtHandoff")).to be(false)
    expect(page.evaluate_script("window.swapsInertAtHandoff")).to be(true)
    expect(page).to have_no_css("#{sheet(0)}[open]")
  end

  it "clears a lost swap's failure when another card's reply shows it stored, so a submit goes through" do
    lose_first_swap_reply
    confirm_swap(0, "challenge")
    expect(page).to have_css("#save-status", visible: :visible)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])

    close_sheet(0)
    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_css("#{sheet(1)}[open]")
    find("#daily-kind-1-pattern").click
    primary(1).click
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_no_css("#save-status", visible: :visible)

    finish_saved(1)
    submit_one_answer
    expect(page).to have_content("✓ Submitted")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
  end

  it "leaves focus in an answer the reader moved to while a swap reply was on its way" do
    hold_swap_replies
    confirm_swap(1, "pattern")
    leave_sheet_saving(1)
    area = find(%(textarea[data-field="code_review"]))
    area.click
    page.driver.with_playwright_page { |pw| pw.keyboard.type("Typed while the swap was saving") }
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_no_css("#{sheet(1)}[open]")
    expect(page.evaluate_script(%(document.activeElement.matches('textarea[data-field="code_review"]')))).to be(true)
    expect(area.value).to include("Typed while the swap was saving")
    page.driver.with_playwright_page { |pw| pw.keyboard.type(" and after") }
    expect(area.value).to include("Typed while the swap was saving and after")
  end

  it "holds the review poll's reload while a swap has failed, and reloads once it saves" do
    response = DailyResponse.create!(user: user, daily_exercise: user.daily_exercises.sole, date: Date.current, submitted_at: Time.current,
                                     reviewing_since: Time.current, answers: { "code_review" => "Submitted with enough detail to count." },
                                     section_ratings: { "code_review" => "right_level" })
    refresh
    wait_for_js
    expect(page).to have_css("[data-controller='generating']")
    fail_first_swap
    response.update!(reviewing_since: nil)
    sleep 4

    expect(page.evaluate_script("window.swapPage")).to be(true)
    retry_swap_and_expect_reload
  end

  it "does not reload over a failed swap when an autosave finds the set regenerated" do
    fail_first_swap
    user.daily_exercises.sole.update!(generated_at: Time.current + 1.minute, regenerated_at: Time.current)
    type_an_answer

    expect(page.evaluate_script("window.swapPage")).to be(true)
    expect_held_autosave
    retry_swap_and_expect_reload
  end

  it "keeps the sheet saving until the reply lands: the primary stays disabled whatever is checked, and nothing dismisses it" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    expect(page).to have_css("#{sheet(0)} [data-daily-kind-swap-target='status']", text: I18n.t("daily_kinds.picker.saving"))
    page.execute_script(<<~JS)
      const radio = document.getElementById("daily-kind-0-pattern");
      radio.checked = true;
      radio.dispatchEvent(new Event("change", { bubbles: true }));
    JS

    expect(primary(0)).to be_disabled
    expect(page.evaluate_script("document.getElementById('daily-kind-0-picker').inert")).to be(true)
    expect(find("#{sheet(0)} .daily-kind-close")).to be_disabled
    expect(find("#{sheet(0)} [data-daily-kind-swap-target='cancel']")).to be_disabled
    find("#daily-kind-0-title").click
    press("Escape")
    page.driver.with_playwright_page { |pw| pw.mouse.click(10, 10) }
    expect(page).to have_css("#{sheet(0)}[open]")

    release_swap
    expect(page).to have_css("#{sheet(0)} .daily-kind-saved", text: I18n.t("daily_kinds.swap.saved"))
    expect(page.evaluate_script("window.heldSwaps.length")).to eq(1)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end

  it "still refreshes both sheets when the page's set is no longer today's" do
    user.daily_exercises.sole.update_columns(date: Date.current - 1)
    confirm_swap(0, "challenge")

    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(trigger_focused?).to be(true)
    expect(panel(1)["data-version"]).to eq(user.reload.section_kind_preferences_version.to_s)
    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
  end

  def expect_cards_left_alone
    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.picker.set_changed"))
    expect(page).to have_no_css("#{sheet(1)}[open]")
    expect(within(panel(0)) { find("button.daily-kind-trigger")["aria-label"] }).to eq("Swap Code Review for another kind")
    expect(panel(1)["data-current"]).to eq("design_comparison")
    expect(find(sheet(1), visible: :all).find("[data-daily-kind-swap-target='cancel']", visible: :all)).not_to be_disabled
  end

  def regenerate_in_another_tab(pair: nil)
    exercise = user.daily_exercises.sole
    user.update!(daily_section_kinds: pair) if pair
    exercise.update!(generated_at: Time.current + 1.minute, regenerated_at: Time.current,
                     plan_notes: exercise.plan_notes.merge("daily_kinds" => pair || DailyKinds::DEFAULT.map(&:key)))
  end

  it "saves but leaves the cards alone when another tab regenerated the set, and says to reload" do
    regenerate_in_another_tab
    confirm_swap(1, "pattern")

    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect_cards_left_alone
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
  end

  it "leaves the cards alone on a stale reply after another tab swapped and regenerated" do
    page.execute_script("window.swapPage = true")
    regenerate_in_another_tab(pair: %w[architecture design_comparison])
    confirm_swap(1, "pattern")

    expect_cards_left_alone
    expect(user.reload.daily_section_kinds).to eq(%w[architecture design_comparison])
    expect(page.evaluate_script("window.swapPage")).to be(true)
  end

  it "says to reload when the page's set can't be found" do
    page.execute_script(%(document.querySelector("[data-daily-kind-swap-url-value='/daily_kinds/1']").dataset.dailyKindSwapExerciseValue = "0"))
    confirm_swap(1, "pattern")

    expect_cards_left_alone
  end

  it "works from the keyboard: Enter opens, the arrows skip a disabled kind, Escape closes and returns focus" do
    trigger = within(panel(0)) { find("button.daily-kind-trigger") }
    expect(trigger["aria-haspopup"]).to eq("dialog")
    expect(trigger["aria-expanded"]).to be_nil
    trigger.send_keys(:enter)

    expect(page).to have_css("#{sheet(0)}[open]")
    expect(page.evaluate_script("document.activeElement.id")).to eq("daily-kind-0-code_review")
    press("ArrowDown")
    expect(page.evaluate_script("document.activeElement.id")).to eq("daily-kind-0-pattern")
    expect(page.evaluate_script("document.activeElement.checked && document.activeElement.dataset.state")).to eq("available")
    expect(primary(0)).not_to be_disabled

    press("Escape")
    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(trigger_focused?).to be(true)
    expect(page).to have_css("#daily-kind-0-code_review:checked", visible: :all)
  end

  it "opens with Space, and the close button resets the choice and returns focus" do
    within(panel(0)) { find("button.daily-kind-trigger") }.send_keys(:space)
    expect(page).to have_css("#{sheet(0)}[open]")
    find("#daily-kind-0-challenge").click

    find("#{sheet(0)} .daily-kind-close").click
    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(trigger_focused?).to be(true)
    expect(page).to have_css("#daily-kind-0-code_review:checked", visible: :all)
  end

  it "reaches the primary and Cancel with Tab, and Cancel returns focus to the trigger" do
    open_sheet(0)
    find("#daily-kind-0-challenge").click
    press("Tab")
    expect(focused("textContent")).to eq("Swap to Coding Challenge")
    press("Tab")
    expect(focused("textContent")).to eq("Cancel")

    press("Enter")
    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(trigger_focused?).to be(true)
  end

  it "keeps focus inside the open sheet" do
    open_sheet(0)
    stops = 12.times.map do
      press("Tab")
      page.evaluate_script(<<~JS)
        (() => {
          const active = document.activeElement;
          if (!active || active === document.body) return "browser";
          return document.getElementById("daily-kind-0-sheet").contains(active) ? "sheet" : active.outerHTML.slice(0, 80);
        })()
      JS
    end

    expect(stops.uniq - %w[sheet browser]).to eq([])
    expect(stops).to include("sheet")
  end

  it "dismisses the sheet on a click on the backdrop, but not on a click or a drag that starts inside it" do
    open_sheet(0)
    find("#daily-kind-0-challenge").click
    find("#daily-kind-0-challenge-short").click
    expect(page).to have_css("#{sheet(0)}[open]")

    box = page.evaluate_script("(() => { const r = document.getElementById('daily-kind-0-challenge-short').getBoundingClientRect(); return [r.left + 5, r.top + 5]; })()")
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(*box)
      pw.mouse.down
      pw.mouse.move(10, 10, steps: 5)
      pw.mouse.up
    end
    expect(page).to have_css("#{sheet(0)}[open]")

    page.driver.with_playwright_page { |pw| pw.mouse.click(10, 10) }
    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(trigger_focused?).to be(true)
    expect(page).to have_css("#daily-kind-0-code_review:checked", visible: :all)
  end

  it "keeps the page behind the sheet from scrolling" do
    page.execute_script("window.scrollTo(0, 200)")
    open_sheet(0)
    scrolled = page.evaluate_script("window.scrollY")

    expect(page.evaluate_script("getComputedStyle(document.documentElement).overflow")).to eq("hidden")
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(10, 10)
      pw.mouse.wheel(0, 600)
    end
    sleep 0.3
    expect(page.evaluate_script("window.scrollY")).to eq(scrolled)

    close_sheet(0)
    expect(page.evaluate_script("getComputedStyle(document.documentElement).overflow")).to eq("visible")
  end

  it "opens an ended trial's sheet onto its close button, with the reason and no list, and Escape closes it" do
    allow_any_instance_of(User).to receive(:trial_ended?).and_return(true)
    refresh
    wait_for_js
    within(panel(0)) { find("button.daily-kind-trigger") }.send_keys(:enter)

    expect(page).to have_css(sheet(0), visible: :visible, text: I18n.t("daily_kinds.swap.refused.trial_ended"))
    expect(page).to have_no_css("#{sheet(0)} .daily-kind-picker")
    expect(focused("getAttribute('aria-label')")).to eq("Close")
    press("Escape")

    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(trigger_focused?).to be(true)
  end

  it "confirms a keyboard choice with Enter on the primary" do
    open_sheet(0)
    find("#daily-kind-0-challenge").click
    primary(0).send_keys(:enter)

    expect(page).to have_css("#{sheet(0)} .daily-kind-saved", text: I18n.t("daily_kinds.swap.saved"))
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end

  it "shows the stored-kind line and the first-time hint under the title row, and only the hint goes after a swap" do
    expect(panel(0)).to have_css(".daily-kind-hint", text: I18n.t("daily_kinds.picker.first_time_hint"))
    expect(panel(1)).to have_no_css(".daily-kind-hint")

    confirm_swap(1, "pattern")
    finish_saved(1)
    expect(panel(0)).to have_no_css(".daily-kind-hint")
    expect(panel(1)).to have_css(".daily-kind-next", text: "Your next set uses Pattern of the Month here.")
  end

  def card_reply(place) = ".daily-kind-swap:has(#daily-kind-swap-panel-#{place}) .daily-kind-reply"

  it "puts the offer for today and its link on the card when the sheet was left during the save" do
    hold_swap_replies
    confirm_swap(1, "pattern")
    leave_sheet_saving(1)
    find(%(textarea[data-field="code_review"])).click
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_no_css("#{sheet(1)}[open]")
    expect(page).to have_css("#{card_reply(1)} p.daily-kind-note", text: I18n.t("daily_kinds.swap.saved"))
    expect(page).to have_css("#{card_reply(1)} p.daily-kind-note", text: I18n.t("daily_kinds.swap.want_it_today"))
    within(card_reply(1)) { click_link I18n.t("daily_kinds.picker.generate_link") }
    expect(page.evaluate_script("document.activeElement === document.querySelector('.regenerate-row form button')")).to be(true)
  end

  it "opens no sheet for a reply that lands while the form is locked for a submit, and puts the offer on the card" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        const body = options?.body ? JSON.parse(options.body) : {};
        if (url.includes("/daily_kinds/")) return new Promise((resolve) => { window.releaseSwap = () => resolve(originalFetch(url, options)); });
        if (body.response?.submit === "1") return new Promise(() => {});
        return originalFetch(url, options);
      };
    JS
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    fill_in_answer("code_review", "An answer submitted while the swap reply is still on its way.")
    rate_section("code_review")
    click_button "Submit answers"
    wait_for_js_condition("document.getElementById('gym-form').inert")
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    sleep 0.3
    expect(page.evaluate_script("Boolean(document.querySelector('dialog[open]'))")).to be(false)
    expect(page).to have_css("#{card_reply(0)} p.daily-kind-note", text: I18n.t("daily_kinds.swap.want_it_today"))
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end

  def fail_held_swap
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        return new Promise((resolve) => { window.releaseSwap = () => resolve(new Response("unavailable", { status: 503 })); });
      };
    JS
  end

  it "keeps a sheet left during the save closed when its failure lands, and shows the choice and error on the next open" do
    fail_held_swap
    confirm_swap(0, "challenge")
    wait_for_js_condition("window.releaseSwap")
    leave_sheet_saving(0, and_run: "window.releaseSwap()")
    wait_for_js_condition("document.activeElement.classList.contains('daily-kind-trigger')")

    expect(page).to have_css("#save-status", visible: :visible)
    sleep 0.3
    expect(page).to have_no_css("#{sheet(0)}[open]")
    expect(trigger_focused?).to be(true)
    open_sheet(0)
    expect(find("#daily-kind-0-challenge")).to be_checked
    expect(page).to have_css("#{sheet(0)} .daily-kind-error", text: I18n.t("save_status.generic"))
    expect(primary(0)["aria-describedby"].split).to include("daily-kind-0-error")
  end

  it "keeps a sheet left during the save closed when a stale reply lands, and shows the stored pair and message on the next open" do
    hold_swap_replies
    confirm_swap(0, "architecture")
    wait_for_js_condition("window.releaseSwap")
    user.update!(daily_section_kinds: %w[pattern design_comparison])
    leave_sheet_saving(0, and_run: "window.releaseSwap()")

    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='pattern']")
    sleep 0.3
    expect(page).to have_no_css("#{sheet(0)}[open]")
    open_sheet(0)
    expect(find("#daily-kind-0-pattern")).to be_checked
    expect(page).to have_css("#{sheet(0)} .daily-kind-error", text: I18n.t("daily_kinds.swap.refused.stale"))
  end

  it "keeps a sheet's saved state when the next card's reply replaces its panel" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    leave_sheet_saving(0)
    confirm_swap(1, "pattern")
    leave_sheet_saving(1)
    open_sheet(0)
    release_swap
    expect(page).to have_css("#{sheet(0)}[open] .daily-kind-saved", text: I18n.t("daily_kinds.swap.saved"))

    wait_for_js_condition("window.heldSwaps.length === 2")
    release_swap
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_css("#{sheet(0)}[open] .daily-kind-saved", text: I18n.t("daily_kinds.swap.want_it_today"))
    expect(page).to have_link(I18n.t("daily_kinds.picker.generate_link"))
    expect(page).to have_no_css("#{sheet(0)} .daily-kind-picker", visible: :visible)
    expect(focused("textContent")).to eq("Done")

    finish_saved(0)
    open_sheet(0)
    expect(page).to have_css("#{sheet(0)} .daily-kind-picker", visible: :visible)
  end

  it "keeps the error and saving live regions rendered while they are empty" do
    open_sheet(0)

    %w[error status].each do |target|
      display = page.evaluate_script("getComputedStyle(document.querySelector('#{sheet(0)} [data-daily-kind-swap-target=\"#{target}\"]')).display")
      expect(display).not_to eq("none"), target
    end
  end

  it "names each radio by its kind and badges only, and keeps a disabled row's reason and badge undimmed" do
    open_sheet(0)
    names = ->(name) { page.driver.with_playwright_page { |pw| pw.get_by_role("radio", name: name, exact: true).count } }

    expect(names.("Code Review Now")).to eq(1)
    expect(names.("Design Comparison Already daily")).to eq(1)
    expect(names.("Coding Challenge")).to eq(1)
    expect(find("#daily-kind-0-challenge")["aria-describedby"].split).to include("daily-kind-0-challenge-short")

    opacity = ->(selector) { page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).opacity") }
    row = "label[data-kind='design_comparison']"
    expect(opacity.("#{row} .daily-kind-name")).to eq("0.6")
    expect(opacity.("#{row} input")).to eq("0.6")
    expect(opacity.(row)).to eq("1")
    expect(opacity.("#{row} .daily-kind-badge")).to eq("1")
    expect(opacity.("#{row} .daily-kind-line")).to eq("1")
  end
end
