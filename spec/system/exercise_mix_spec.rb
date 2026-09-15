require "rails_helper"

# The sliders persist through an inline listener that PATCHes /profile — no form
# submit, no Turbo. A request spec exercises that endpoint directly, so it stays
# green even if the listener is deleted or posts the wrong stop; only a real
# browser round trip covers the wiring between the two.
RSpec.describe "Exercise mix", type: :system do
  let(:user) { create_fake_provider_user }

  # The fetch resolves independently of Capybara, so the assertion waits on the
  # write rather than the DOM, which already shows the new state optimistically.
  def weights_after_save(timeout: 5)
    deadline = Time.current + timeout
    sleep 0.1 while user.reload.section_kind_weights.empty? && Time.current < deadline
    user.reload.section_kind_weights
  end

  it "saves a slider's stop and shows its label" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click
    find("#weight-challenge").set(0)

    expect(find("#weight-label-challenge")).to have_text("Much less")
    expect(weights_after_save).to eq("challenge" => 0.25)
  end

  it "locks the last remaining kind in a group rather than letting a slot empty" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click

    ExerciseSection.fourths.first(ExerciseSection.fourths.size - 1).each do |kind|
      find("#exclude-#{kind.key}").click
    end

    last = ExerciseSection.fourths.last

    expect(find("#exclude-#{last.key}")).to be_disabled
    expect(page).to have_text("At least one section in this group has to stay in rotation.")
  end
end
