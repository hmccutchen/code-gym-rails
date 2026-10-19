require "rails_helper"

RSpec.describe "Swapping a daily section kind", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    visit_with_todays_set(user)
    wait_for_js
  end

  def panel(place) = find("#daily-kind-swap-panel-#{place}")

  def open_picker(place)
    within(panel(place)) { find("button.daily-kind-trigger").click }
    expect(page).to have_css("#daily-kind-#{place}-picker", visible: :visible)
  end

  def confirm_swap(place, kind)
    open_picker(place)
    find("#daily-kind-#{place}-#{kind}").click
    within("#daily-kind-#{place}-picker") { click_button "Confirm" }
  end

  it "opens the picker with the current kind checked and the other daily kind disabled with its reason" do
    open_picker(0)

    expect(find("#daily-kind-0-code_review")).to be_checked
    expect(find("#daily-kind-0-design_comparison")).to be_disabled
    expect(page).to have_css("#daily-kind-0-design_comparison-note", text: "Already a daily section")
    expect(page).to have_css("#daily-kind-0-picker", text: I18n.t("daily_kinds.picker.next_set"))
    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: true)
  end

  it "points each radio at its guide, and shows the chosen option's consequences" do
    open_picker(0)
    radio = find("#daily-kind-0-challenge")

    expect(radio["aria-describedby"].split).to include("daily-kind-0-challenge-guide")
    expect(page).to have_css("#daily-kind-0-challenge-guide", visible: :all)

    radio.click
    expect(page).to have_css("#daily-kind-0-challenge-summary", visible: :visible)
    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: false)
  end

  it "saves a swap, shows the server's message and refreshes both pickers with the new version" do
    version = panel(0)["data-version"]
    confirm_swap(0, "challenge")

    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(page).to have_link(I18n.t("daily_kinds.picker.generate_link"))
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
    expect(panel(0)["data-version"]).not_to eq(version)
    expect(panel(1)["data-version"]).to eq(panel(0)["data-version"])
    expect(panel(0)["data-current"]).to eq("challenge")

    open_picker(1)
    expect(find("#daily-kind-1-challenge")).to be_disabled
  end

  it "takes two swaps in a row without a reload" do
    page.execute_script("window.swapPage = true")
    confirm_swap(0, "challenge")
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")

    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
    expect(page.evaluate_script("window.swapPage")).to be(true)
  end

  it "shows the stale message, reopens the picker on the pair another tab stored, and saves on the next try" do
    user.update!(daily_section_kinds: %w[pattern design_comparison])
    confirm_swap(0, "architecture")

    expect(page).to have_css("#save-status", text: I18n.t("daily_kinds.swap.refused.stale"))
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='pattern']")
    expect(page).to have_css("#daily-kind-0-picker", visible: :visible)
    expect(page.evaluate_script("document.activeElement.id")).to eq("daily-kind-0-pattern")
    expect(user.reload.daily_section_kinds).to eq(%w[pattern design_comparison])

    find("#daily-kind-0-architecture").click
    within("#daily-kind-0-picker") { click_button "Confirm" }
    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(user.reload.daily_section_kinds).to eq(%w[architecture design_comparison])
  end

  it "shows a refusal in the banner and keeps the picker open with focus on Confirm" do
    open_picker(0)
    find("#daily-kind-0-challenge").click
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.includes("/daily_kinds/")
        ? Promise.resolve(new Response(JSON.stringify({ status: "invalid", error: "That swap couldn't be saved." }), { status: 422, headers: { "Content-Type": "application/json" } }))
        : originalFetch(url, options);
    JS
    within("#daily-kind-0-picker") { click_button "Confirm" }

    expect(page).to have_css("#save-status", text: "That swap couldn't be saved.")
    expect(page).to have_css("#daily-kind-0-picker", visible: :visible)
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("Confirm")
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

  def focused(script) = page.evaluate_script("document.activeElement.#{script}")

  it "reopens a queued card refused after the first card's swap, focused on a control it can use" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    confirm_swap(1, "challenge")
    release_swap
    wait_for_js_condition("window.heldSwaps.length === 2")
    release_swap

    expect(page).to have_css("#save-status", text: I18n.t("daily_kinds.swap.refused.already_daily"))
    expect(page).to have_css("#daily-kind-1-picker", visible: :visible)
    expect(find("#daily-kind-1-challenge")).to be_disabled
    expect(focused("disabled")).to be(false)
    expect(focused("id")).to eq("daily-kind-1-design_comparison")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end

  it "reopens a queued card whose swap failed in transit with its choice kept and Confirm focused" do
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
    confirm_swap(1, "pattern")
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_css("#daily-kind-1-picker", visible: :visible)
    expect(find("#daily-kind-1-pattern")).to be_checked
    expect(focused("textContent")).to eq("Confirm")
    expect(focused("disabled")).to be(false)

    within("#daily-kind-1-picker") { click_button "Confirm" }
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
    confirm_swap(1, "pattern")
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_css("#save-status", visible: :visible)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])

    confirm_swap(0, "challenge")
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_no_css("#save-status", visible: :visible)
  end

  def submit_one_answer
    page.execute_script("window.swapPage = true")
    fill_in_answer("code_review", "The answer that is submitted while both swaps are still queued.")
    rate_section("code_review")
    click_button "Submit answers"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    sleep 0.05 until user.daily_responses.reload.first&.submitted? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(user.daily_responses.sole).to be_submitted
  end

  it "waits for queued swaps to save before a submit leaves the page" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    confirm_swap(1, "pattern")
    submit_one_answer

    expect(page.evaluate_script("window.swapPage")).to be(true)
    release_swap
    wait_for_js_condition("window.heldSwaps.length === 2")
    release_swap

    expect(page).to have_content("✓ Submitted", wait: 10)
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
    confirm_swap(1, "pattern")
    submit_one_answer
    release_swap

    expect_held
    sleep 1.5
    expect(page.evaluate_script("window.swapPage")).to be(true)
    expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(false)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])

    expect(find("#daily-kind-1-pattern")).to be_checked
    within("#daily-kind-1-picker") { click_button "Confirm" }
    release_swap
    expect(page).to have_content("✓ Submitted", wait: 10)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
  end

  def expect_held
    expect(page).to have_css("#save-status", visible: :visible)
    expect(page).to have_css("#leave-held", text: I18n.t("dashboard.exercise.leave_held"))
    expect(page).to have_css("#leave-held button", text: I18n.t("dashboard.exercise.reload_now"))
    expect(page).to have_button("Submit answers", disabled: true)
  end

  it "keeps answers read-only while a submit is held, so no edit is silently dropped" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.includes("/daily_kinds/")
        ? Promise.resolve(new Response("unavailable", { status: 503 }))
        : originalFetch(url, options);
    JS
    confirm_swap(1, "pattern")
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
    within("#daily-kind-1-picker") { click_button "Confirm" }
    wait_for_js_condition("window.swapPage === undefined", timeout: 8)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
  end

  it "freezes the answers as soon as an autosave waits on a swap, and reloads once the swap lands" do
    hold_swap_replies
    confirm_swap(1, "pattern")
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
    expect(page).to have_css("#leave-held", wait: 15)

    page.execute_script("window.releaseAutosave()")
    wait_for_js_condition("window.reviewHandoffs === 1")
    sleep 1.5
    expect(page.evaluate_script("window.swapPage")).to be(true)
    expect(page.evaluate_script("window.reviewHandoffs")).to eq(1)
  end

  it "clears a card's failure when the retry finds its lost swap already stored" do
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
    confirm_swap(1, "pattern")
    expect(page).to have_css("#save-status", visible: :visible)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])

    within("#daily-kind-1-picker") { click_button "Confirm" }
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_no_css("#save-status", visible: :visible)
    expect(page).to have_css("#daily-kind-1-picker", visible: :hidden)
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

  it "locks the swap controls again when a held submit resumes into the review" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.swapCalls = 0;
      window.fetch = (url, options) => {
        if (!url.includes("/daily_kinds/")) return originalFetch(url, options);
        window.swapCalls += 1;
        if (window.swapCalls === 1) return Promise.resolve(new Response("unavailable", { status: 503 }));
        return originalFetch(url, options);
      };
      HTMLFormElement.prototype.submit = function () {
        window.handoffs = (window.handoffs || 0) + 1;
        window.swapsInertAtHandoff = Boolean(document.querySelector(".daily-kind-swap").closest("[inert]"));
      };
    JS
    confirm_swap(1, "pattern")
    submit_one_answer
    expect_held

    within("#daily-kind-1-picker") { click_button "Confirm" }
    wait_for_js_condition("window.handoffs === 1")
    expect(page.evaluate_script("window.swapsInertAtHandoff")).to be(true)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review pattern])
  end

  it "clears a lost swap's failure when another card's reply shows it stored, so a submit goes through" do
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
    confirm_swap(0, "challenge")
    expect(page).to have_css("#save-status", visible: :visible)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])

    within(panel(0)) { find("button.daily-kind-trigger").click }
    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(page).to have_css("#daily-kind-1-picker", visible: :visible)
    find("#daily-kind-1-pattern").click
    within("#daily-kind-1-picker") { click_button "Confirm" }
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(page).to have_no_css("#save-status", visible: :visible)

    submit_one_answer
    expect(page).to have_content("✓ Submitted", wait: 10)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
  end

  it "leaves focus in an answer the reader moved to while a swap reply was on its way" do
    hold_swap_replies
    confirm_swap(1, "pattern")
    area = find(%(textarea[data-field="code_review"]))
    area.click
    page.driver.with_playwright_page { |pw| pw.keyboard.type("Typed while the swap was saving") }
    release_swap

    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
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

  it "keeps Confirm disabled while a swap is on its way, whatever radio is chosen" do
    hold_swap_replies
    confirm_swap(0, "challenge")
    find("#daily-kind-0-pattern").click

    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: true)
    release_swap
    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(page.evaluate_script("window.heldSwaps.length")).to eq(1)
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end

  it "still refreshes both pickers when the page's set is no longer today's" do
    user.daily_exercises.sole.update_columns(date: Date.current - 1)
    confirm_swap(0, "challenge")

    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")
    expect(panel(1)["data-version"]).to eq(user.reload.section_kind_preferences_version.to_s)
    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
  end

  def expect_cards_left_alone
    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.picker.set_changed"))
    expect(page).to have_css("#daily-kind-1-picker", visible: :hidden)
    expect(within(panel(0)) { find("button.daily-kind-trigger").text }).to eq("Swap Code Review")
    expect(panel(1)["data-current"]).to eq("design_comparison")
    expect(find("#daily-kind-1-picker", visible: :all).find_button("Cancel", visible: :all)).not_to be_disabled
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

  it "works from the keyboard: open, arrow to a kind, Escape closes and returns focus" do
    trigger = within(panel(0)) { find("button.daily-kind-trigger") }
    trigger.send_keys(:enter)

    expect(page.evaluate_script("document.activeElement.id")).to eq("daily-kind-0-code_review")
    page.driver.with_playwright_page { |pw| pw.keyboard.press("ArrowDown") }
    expect(page.evaluate_script("document.activeElement.checked && document.activeElement.dataset.state")).to eq("available")
    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: false)

    page.driver.with_playwright_page { |pw| pw.keyboard.press("Escape") }
    expect(page).to have_css("#daily-kind-0-picker", visible: :hidden)
    expect(trigger["aria-expanded"]).to eq("false")
    expect(page.evaluate_script("document.activeElement.classList.contains('daily-kind-trigger')")).to be(true)
    expect(find("#daily-kind-0-code_review", visible: :all)).to be_checked
  end

  it "opens an ended trial's empty picker onto Cancel, and Escape closes it" do
    allow_any_instance_of(User).to receive(:trial_ended?).and_return(true)
    refresh
    wait_for_js
    trigger = within(panel(0)) { find("button.daily-kind-trigger") }
    trigger.send_keys(:enter)

    expect(page).to have_css("#daily-kind-0-picker", visible: :visible, text: I18n.t("daily_kinds.swap.refused.trial_ended"))
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("Cancel")
    page.driver.with_playwright_page { |pw| pw.keyboard.press("Escape") }

    expect(page).to have_css("#daily-kind-0-picker", visible: :hidden)
    expect(page.evaluate_script("document.activeElement.classList.contains('daily-kind-trigger')")).to be(true)
  end

  it "confirms a keyboard choice with Enter on Confirm" do
    open_picker(0)
    find("#daily-kind-0-challenge").click
    within("#daily-kind-0-picker") { find_button("Confirm").send_keys(:enter) }

    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end
end
