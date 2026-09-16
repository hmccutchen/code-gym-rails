require "rails_helper"

# The sliders persist through an inline listener that PATCHes /profile — no form
# submit, no Turbo. A request spec exercises that endpoint directly, so it stays
# green even if the listener is deleted or posts the wrong stop; only a real
# browser round trip covers the wiring between the two.
RSpec.describe "Exercise mix", type: :system do
  let(:user) { create_fake_provider_user }

  # The fetch resolves independently of Capybara, so these wait on the write
  # rather than the DOM, which already shows the new state optimistically.
  # Polling until the value MATCHES, not merely until it is present: the saves
  # are debounced and a click can land an intermediate write first, and a poll
  # that stopped at "non-empty" would compare against that instead.
  def weights_after_save(expected, timeout: 5)
    wait_for(timeout) { user.reload.section_kind_weights == expected }
    user.reload.section_kind_weights
  end

  def exclusions_after_save(expected, timeout: 5)
    wait_for(timeout) { user.reload.excluded_section_kinds.sort == expected.sort }
    user.reload.excluded_section_kinds
  end

  def wait_for(timeout)
    deadline = Time.current + timeout
    sleep 0.1 until yield || Time.current > deadline
  end

  # Gaining or losing a target now reloads the page on its own (see
  # api_keys/edit's saveMix), so a test that follows one with its own explicit
  # `visit` would race that reload. A marker on the live document, gone once a
  # fresh document replaces it, tells the two apart without depending on
  # timing.
  def wait_for_reload(timeout: 5)
    page.execute_script("window.__reloadMarker = true")
    wait_for(timeout) { !marker_present? }
  end

  def marker_present?
    page.evaluate_script("window.__reloadMarker") == true
  rescue StandardError
    true
  end

  it "saves a slider's stop and shows its label" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click
    find("#weight-challenge").set(0)

    expect(find("#weight-label-challenge")).to have_text("Much less")
    expect(weights_after_save({ "challenge" => 0.25 })).to eq("challenge" => 0.25)
  end

  # The two-tab clobber from the original report. The second tab's save is a
  # write against a version this page has not seen, which is what user.update!
  # produces here — the same bump a real save in another tab makes, without a
  # second browser window's timing to fight.
  it "refuses a save from a page whose controls predate another save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.update!(excluded_section_kinds: [ "parsons_problem" ])

    find("#weight-challenge").set(0)

    expect(page).to have_css("#save-status", text: /changed in another tab/i, wait: 5)
    expect(user.reload.section_kind_weights).to eq({})
    # Re-synced rather than left showing a change the server rejected.
    expect(find("#exclude-parsons_problem")).to be_checked
  end

  # The precondition's own hazard: this tab racing itself. The debounce only
  # spaces saves by 400ms, so a request slower than that is still in flight
  # when the next one is sent, and that next one posts a version the first is
  # about to move. Holding every response past the debounce reproduces it
  # without needing a slow network.
  #
  # Unchained, the first save commits and bumps, the second is refused as a
  # conflict with its own predecessor, and applyServerState snaps the slider
  # back — leaving 0.25 stored, the value the engineer had already moved off.
  it "does not refuse a second save issued while this tab's first is in flight" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    hold_profile_saves(2500)

    find("#weight-challenge").set(0)
    sleep 0.8
    find("#weight-challenge").set(4)

    expect(weights_after_save({ "challenge" => 4.0 }, timeout: 15)).to eq("challenge" => 4.0)
  end

  # Delays the page's handling of its own save responses, which is what "slower
  # than the debounce" means from the script's side. Delaying the request
  # instead would reorder arrivals at the server and stop reproducing this.
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
    expect(page).to have_text("At least one section in this group has to stay in rotation.")
    # The lock is drawn by lockLastInGroup, which runs whether or not the click
    # also saved — so without this the example passes with the autosave deleted.
    expect(exclusions_after_save(excluded.map(&:key))).to contain_exactly(*excluded.map(&:key))
  end

  def difficulty_after_save(levels, locked, timeout: 5)
    wait_for(timeout) { user.reload.section_kind_levels == levels && user.locked_section_kinds.sort == locked.sort }
    [ user.reload.section_kind_levels, user.locked_section_kinds ]
  end

  it "gives fixed sections difficulty controls and no slider or exclude" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    within(".mix-difficulty[data-kind='code_review']") do
      expect(page).to have_field("level-code_review", type: "radio", count: KindDifficulty::LEVELS.size + 1)
    end
    expect(page).not_to have_css("#weight-code_review")
    expect(page).not_to have_css("#exclude-code_review")
  end

  it "saves a level and a lock, and keeps them across a reload" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    expect(find("#lock-code_review")).to be_disabled
    find(".mix-difficulty[data-kind='code_review'] input[value='principal_engineer']").click
    expect(find("#lock-code_review")).not_to be_disabled
    find("#lock-code_review").click

    expect(difficulty_after_save({ "code_review" => "principal_engineer" }, [ "code_review" ]))
      .to eq([ { "code_review" => "principal_engineer" }, [ "code_review" ] ])

    # code_review just went from untargeted to targeted, which reloads the
    # page on its own -- wait for that instead of visiting again and racing it.
    wait_for_reload
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

    expect(find(".mix-difficulty[data-kind='pattern'] .mix-coverage")).to have_text(/of \d+ concepts have difficulty notes/)
  end

  # The bulk control's count is server-rendered and deduplicated across kinds,
  # so the page has to actually reload to pick up a first target -- there is
  # no client-side script that keeps it in sync on its own.
  it "makes the bulk difficulty-notes control available after a first target, without a manual reload" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    expect(page).not_to have_css(".mix-ladders")

    find(".mix-difficulty[data-kind='pattern'] input[value='junior']").click

    # The reload collapses the <details> back to closed, so the control is
    # present but not visible until it is reopened -- checked with visible:
    # :all first to confirm the reload actually happened.
    expect(page).to have_css(".mix-ladders", visible: :all, wait: 5)
    expect(user.reload.section_kind_levels).to eq("pattern" => "junior")

    find("#exercise-mix summary").click
    expect(page).to have_css(".mix-ladders")
  end

  it "restores levels and locks from the server after a refused save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.update!(section_kind_levels: { "pattern" => "senior" }, locked_section_kinds: [ "pattern" ])

    find(".mix-difficulty[data-kind='code_review'] input[value='junior']").click

    expect(page).to have_css("#save-status", text: /changed in another tab/i, wait: 5)
    expect(find(".mix-difficulty[data-kind='pattern'] input[value='senior']")).to be_checked
    expect(find("#lock-pattern")).to be_checked
    expect(find(".mix-difficulty[data-kind='code_review'] input[value='']")).to be_checked
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
    wait_for(5) { page.evaluate_script("window.mixResponses?.length") == count }
    expect(page.evaluate_script("window.mixResponses?.length")).to eq(count)
  end

  [ "pending", "queued" ].each do |phase|
    it "flushes a #{phase} lock and weight edit before reloading for a saved target" do
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
        wait_for(5) { page.evaluate_script("window.mixDebounces") == 2 }
        expect(page.evaluate_script("window.mixDebounces")).to eq(2)
        page.execute_script("window.mixResponses[0]()")
      end

      wait_for_mix_responses(2)
      expect(page).not_to have_css(".mix-ladders", visible: :all)
      page.execute_script("window.mixResponses[1]()")

      expect(page).to have_css(".mix-ladders", visible: :all)
      find("#exercise-mix summary").click
      expect(find("#lock-code_review")).to be_checked
      expect(find("#weight-label-challenge")).to have_text("Much less")
      expect(user.reload.locked_section_kinds).to eq([ "code_review" ])
      expect(user.section_kind_weights).to eq("challenge" => 0.25)
    end
  end

  it "keeps a failed pending edit visible until a later successful save can reload" do
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
    expect(page).not_to have_css(".mix-ladders", visible: :all)

    find("#weight-challenge").set(0)
    wait_for_mix_responses(3)
    page.execute_script("window.mixResponses[2]()")

    expect(page).to have_css(".mix-ladders", visible: :all)
    expect(user.reload.locked_section_kinds).to eq([ "code_review" ])
    expect(user.section_kind_weights).to eq("challenge" => 0.25)
  end
end
