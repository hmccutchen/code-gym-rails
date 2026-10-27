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

  it "renders on History too" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)
    reviewed_day(date: Date.current - 1)

    expect(short_version(history_path)).to be_present
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
