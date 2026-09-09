require "rails_helper"

# The filter script matches against dataset attributes a request spec never
# executes, so the mismatch between the humanized label people actually see
# and the raw key alone in data-concept survived to manual review. This pins
# the visible behavior: typing what is on the screen has to narrow the list.
RSpec.describe "Learn tab filter", type: :system do
  def seeded_reference(concept:, language: "ruby_rails")
    ConceptReference.create!(
      concept: concept, language: language,
      tagline: "One clear rule, not a grab-bag of tips.",
      explanation: "This concept has one core idea worth internalizing.",
      code_example: "def example; true; end",
      senior_lens: "A senior engineer reaches for this automatically."
    )
  end

  it "narrows to the matching entry when typing the displayed, humanized label" do
    user = create_fake_provider_user
    user.update!(language: "ruby_rails")
    seeded_reference(concept: "n_plus_one")

    visit_as(user)
    visit learn_path
    expect(page).to have_content("Learn")

    fill_in "Filter concepts", with: "n plus one"

    expect(page).to have_css(".learn-entry", visible: :visible, count: 1)
    expect(page).to have_content("N plus one")
    expect(page).to have_no_css("#learn-empty", visible: :visible)
  end

  it "hides every entry and shows the empty state for a non-matching term" do
    user = create_fake_provider_user
    user.update!(language: "ruby_rails")
    seeded_reference(concept: "n_plus_one")

    visit_as(user)
    visit learn_path
    expect(page).to have_content("Learn")

    fill_in "Filter concepts", with: "no such concept anywhere"

    expect(page).to have_no_css(".learn-entry", visible: :visible)
    expect(page).to have_css("#learn-empty", visible: :visible)
    expect(page).to have_content("No concepts match that.")
  end
end
