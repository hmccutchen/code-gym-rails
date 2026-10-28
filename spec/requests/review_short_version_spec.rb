require "rails_helper"

RSpec.describe "The concept's short version in a review", type: :request do
  let(:user) { create_user_with_key }
  let(:guide) do
    { tagline: "Load the rows you loop over in one query", explanation: "The explanation.",
      code_example: "Order.includes(:customer)", senior_lens: "The senior lens.",
      guide_plain_language: "Each pass of the loop asks the database again.",
      guide_worked_example: "Before the fix, each order loads its customer.",
      guide_pitfalls: "Preloading an association the loop never reads." }
  end

  def reviewed_day(date:, rating: "developing", gaps: [ 0 ], concept: "n_plus_one")
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => concept } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "Add includes before the loop." },
      section_ratings: { "code_review" => "right_level" },
      concept_tags: { "code_review" => concept },
      ai_review: { "code_review" => { "rating" => rating, "correct" => [ "You found the loop." ],
                                      "missed" => [ "The customer loads once per order." ], "essential_gaps" => gaps } }
    )
  end

  def short_version(path)
    get path
    Nokogiri::HTML(response.body).at_css(".review-block details.review-short-version")
  end

  before { login_as(user) }

  it "renders closed on the submitted dashboard, with its summary, the guide and a link to the concept" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current)

    block = short_version(root_path)

    expect(block).to be_present
    expect(block["open"]).to be_nil
    expect(block.at_css("summary").text).to eq(I18n.t("review.short_version.summary"))
    expect(block.text).to include(guide[:tagline], guide[:guide_plain_language], guide[:guide_worked_example])
    expect(block.at_css("a")["href"]).to eq(learn_concept_path("ruby_rails", "n_plus_one"))
  end

  it "builds the exposure index once for the submitted dashboard" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current)

    builds = 0
    counter = ->(*, payload) { builds += 1 if payload[:sql].include?(%("daily_exercises"."language" FROM "daily_responses")) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }

    expect(Nokogiri::HTML(response.body).css("details.review-short-version").size).to eq(1)
    expect(builds).to eq(1)
  end

  it "renders on History too" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current - 1)

    expect(short_version(history_path)).to be_present
  end

  it "keeps the block but drops the Learn link for a bucket outside the user's current language" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current - 1)
    user.update!(language: "javascript")

    block = short_version(history_path)

    expect(block).to be_present
    expect(block.css("a")).to be_empty
  end

  it "renders nothing when the concept has no reference row" do
    reviewed_day(date: Date.current)

    expect(short_version(root_path)).to be_nil
  end

  it "renders nothing on a later exposure with a solid grade" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current - 7, rating: "solid", gaps: [])
    reviewed_day(date: Date.current, rating: "solid", gaps: [])

    expect(short_version(root_path)).to be_nil
  end

  it "falls back to the explanation and code example for a row with no guide" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             **guide.except(:guide_plain_language, :guide_worked_example, :guide_pitfalls))
    reviewed_day(date: Date.current)

    block = short_version(root_path)

    expect(block.text).to include(guide[:explanation])
    expect(block.at_css("pre.snippet").text).to include("Order.includes(:customer)")
  end

  it "shows pitfalls only when the section has an essential gap" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current - 1, rating: "developing", gaps: [ 0 ])
    reviewed_day(date: Date.current - 2, rating: "solid", gaps: [], concept: "n_plus_one_two")
    ConceptReference.create!(concept: "n_plus_one_two", language: "ruby_rails", **guide)

    get history_path
    blocks = Nokogiri::HTML(response.body).css(".review-block details.review-short-version")

    expect(blocks.map { |block| block.text.include?(guide[:guide_pitfalls]) }).to eq([ true, false ])
  end

  def two_section_day(reviews:)
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
                     "pattern" => { "title" => "t", "question" => "p", "concept" => "n_plus_one" } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "Add includes.", "pattern" => "Preload it." },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
      concept_tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" }, ai_review: reviews
    )
  end

  def blocks_by_section
    get root_path
    Nokogiri::HTML(response.body).css(".review-block").to_h do |block|
      [ block["data-slot"], block.css("details.review-short-version").size ]
    end
  end

  it "renders one block for two sections sharing a concept, with pitfalls when either has the gap" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    two_section_day(reviews: { "code_review" => { "rating" => "solid", "missed" => [], "essential_gaps" => [] },
                               "pattern" => { "rating" => "developing", "missed" => [ "m" ], "essential_gaps" => [ 0 ] } })

    expect(blocks_by_section.values.sum).to eq(1)
    expect(Nokogiri::HTML(response.body).at_css("details.review-short-version").text).to include(guide[:guide_pitfalls])
  end

  it "renders the block on the later section when the earlier one's review failed" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    two_section_day(reviews: { "pattern" => { "rating" => "developing", "missed" => [ "m" ], "essential_gaps" => [ 0 ] } })

    page = blocks_by_section
    expect(page.values.sum).to eq(1)
    expect(Nokogiri::HTML(response.body).at_css(".review-block details.review-short-version")
             .ancestors(".review-block").first.at_css("h3").text).to include("Pattern")
  end

  it "escapes markup in every reference field it shows" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             **guide.merge(guide_worked_example: "<i>worked</i> example", guide_pitfalls: "<i>pitfall</i> text"))
    reviewed_day(date: Date.current)
    with_guide = short_version(root_path)

    ConceptReference.delete_all
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             **guide.except(:guide_plain_language, :guide_worked_example, :guide_pitfalls)
                                   .merge(explanation: "<i>explained</i>", code_example: "<i>code</i>"))
    without_guide = short_version(root_path)

    [ with_guide, without_guide ].each { |block| expect(block.css("i")).to be_empty }
    expect(with_guide.text).to include("<i>worked</i> example", "<i>pitfall</i> text")
    expect(without_guide.text).to include("<i>explained</i>", "<i>code</i>")
  end

  it "underlines a glossary term once across the block and escapes markup in reference fields" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             **guide.merge(tagline: "<b>Bold</b> eager loading",
                                           guide_plain_language: "Use eager loading here."))
    reviewed_day(date: Date.current)

    block = short_version(root_path)

    expect(block.css(".gloss-term").map(&:text)).to eq([ "eager loading" ])
    expect(block.css("b")).to be_empty
    expect(block.text).to include("<b>Bold</b>")
  end
end
