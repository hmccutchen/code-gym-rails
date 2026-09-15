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

    expect(find(".mix-difficulty[data-kind='pattern'] .mix-coverage")).to have_text(/of \d+ concepts have difficulty notes/)
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
end
