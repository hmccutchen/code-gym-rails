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
end
