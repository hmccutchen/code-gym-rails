require "rails_helper"

# The filter matches a rendered attribute request specs never execute; typing the visible label must narrow the list.
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

  def visit_learn_as(language)
    user = create_fake_provider_user
    user.update!(language: language)
    visit_as(user)
    visit learn_path
    expect(page).to have_content("Learn")
  end

  def visible_entries
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".learn-entry")].filter((entry) => entry.checkVisibility())
        .map((entry) => entry.querySelector("a").getAttribute("href"))
    JS
  end

  def visible_concepts
    visible_entries.map { |href| href.split("/").last }
  end

  def entries_with_a_word_starting(prefix)
    searches = page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".learn-entry")]
        .map((entry) => [ entry.querySelector("a").getAttribute("href").split("/").pop(), entry.dataset.search ])
    JS
    searches.select { |_concept, search| search.scan(/[\p{L}\p{N}+]+/).any? { |word| word.start_with?(prefix) } }.map(&:first)
  end

  def filter_to(term, expected)
    fill_in "Filter concepts", with: term
    expect(page).to have_css(".learn-entry", visible: :visible, count: expected.size)
    expect(visible_concepts).to match_array(expected), "#{term.inspect} showed #{visible_concepts}"
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

  it "finds concepts through typos, partial words, synonyms, and group and bucket names" do
    visit_learn_as("ruby_rails")

    filter_to "memoizd", %w[memoization]
    filter_to "idempotncy", %w[idempotency idempotency_at_scale]
    filter_to "n+1", %w[n_plus_one]
    filter_to "n + 1", %w[n_plus_one]
    filter_to "code smell", ConceptVocabulary::CODE_SMELL_CONCEPTS
    filter_to "code", ConceptVocabulary::CODE_SMELL_CONCEPTS + ConceptVocabulary::PSEUDOCODE_TO_CODE_CONCEPTS + %w[reading_unfamiliar_code]
    filter_to "in", entries_with_a_word_starting("in")
    filter_to "ruby", ConceptVocabulary::RAILS_CONCEPTS + %w[reading_unfamiliar_code]
  end

  it "allows one edit from five letters and two from eight, counting a swap as one even beside another edit" do
    visit_learn_as("ruby_rails")

    filter_to "cahce", %w[cache_key_completeness]
    filter_to "idmpotn", []
    filter_to "valdaton", %w[validations semantic_input_validation]
    filter_to "idmptncy", []
    filter_to "arictecture", ConceptVocabulary::ARCHITECTURE_CONCEPTS
    filter_to "mémoization", %w[memoization]
  end

  it "ranks a prefix match above a typo within a group" do
    visit_learn_as("ruby_rails")

    filter_to "inher", %w[composition_over_inheritance dependency_inversion]
    expect(visible_concepts).to eq(%w[composition_over_inheritance dependency_inversion])
  end

  it "allows no typo in a word under five letters" do
    visit_learn_as("ruby_rails")

    fill_in "Filter concepts", with: "such"

    expect(page).to have_no_css(".learn-entry", visible: :visible)
    expect(page).to have_css("#learn-empty", visible: :visible)
  end

  it "ranks a stronger match first within its group, and restores the page order once cleared" do
    visit_learn_as("ruby_rails")
    page_order = visible_concepts
    expect(page_order.index("scaling_bottlenecks")).to be < page_order.index("idempotency_at_scale")

    filter_to "scale", %w[idempotency_at_scale scaling_bottlenecks]
    expect(visible_concepts).to eq(%w[idempotency_at_scale scaling_bottlenecks])

    fill_in "Filter concepts", with: ""
    expect(page).to have_css(".learn-entry", visible: :visible, count: page_order.size)
    expect(visible_concepts).to eq(page_order)
  end

  it "shows a whole group when the query names it, and hides the groups it empties" do
    visit_learn_as("ruby_rails")

    filter_to "code smell", ConceptVocabulary::CODE_SMELL_CONCEPTS

    expect(page).to have_css("#learn-group-ruby_rails-code_smell", visible: :visible)
    expect(page).to have_no_css("#learn-group-ruby_rails-core", visible: :visible)
  end

  it "shows a concept both languages hold once under each, until the query names a language" do
    visit_learn_as("mixed")

    fill_in "Filter concepts", with: "god object"
    expect(page).to have_css(".learn-entry", visible: :visible, count: 2)
    expect(visible_entries).to match_array([ "/learn/ruby_rails/god_object", "/learn/javascript/god_object" ])

    fill_in "Filter concepts", with: "javascript god object"
    expect(page).to have_css(".learn-entry", visible: :visible, count: 1)
    expect(visible_entries).to eq([ "/learn/javascript/god_object" ])
  end

  it "closes the keyboard on Enter and keeps the filter applied" do
    visit_learn_as("ruby_rails")

    fill_in "Filter concepts", with: "memoizd"
    find("#learn-filter-input").send_keys(:enter)

    wait_for { page.evaluate_script("document.activeElement.id") != "learn-filter-input" }
    expect(visible_concepts).to eq(%w[memoization])
  end
end
