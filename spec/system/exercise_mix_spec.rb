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
