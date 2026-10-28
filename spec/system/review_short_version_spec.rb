require "rails_helper"

RSpec.describe "The concept's short version in a review, on a phone", type: :system do
  around { |example| travel_to(a_weekday) { example.run } }

  let(:user) { create_fake_provider_user }

  def submitted_day
    exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                                     problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_dup)
    keys = exercise.active_section_keys
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: keys.index_with { "Preload the customers before the loop." },
      section_ratings: keys.index_with { "right_level" },
      concept_tags: { "code_review" => "n_plus_one" },
      ai_review: { "code_review" => { "rating" => "developing", "missed" => [ "Loads each customer alone." ], "essential_gaps" => [ 0 ] } }
    )
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "Load what the loop reads in one query",
                             explanation: "e", code_example: "Order.includes(:customer)", senior_lens: "s",
                             guide_plain_language: "Reach for eager loading when a loop reads an association.",
                             guide_worked_example: "Before the fix, each order loads its customer.",
                             guide_pitfalls: "Preloading an association the loop never reads.")
  end

  def summary_line_count
    page.evaluate_script(<<~JS)
      (() => {
        const range = document.createRange();
        range.selectNodeContents(document.querySelector("details.review-short-version > summary"));
        return new Set(Array.from(range.getClientRects()).map((r) => Math.round(r.top))).size;
      })()
    JS
  end

  def opened_term_panel_display
    page.evaluate_script(<<~JS)
      (() => {
        const term = document.querySelector("details.review-short-version .gloss-term");
        term.click();
        return getComputedStyle(term, "::after").display;
      })()
    JS
  end

  it "loads closed on one line at 360px, opens on a tap, and opens a glossary term inside it" do
    submitted_day
    resize(360, height: 800)
    visit_as(user)

    block = find("details.review-short-version")
    expect(block[:open]).to be_nil
    expect(summary_line_count).to eq(1)

    block.find("summary").click
    expect(page).to have_css("details.review-short-version[open]")
    expect(page).to have_css("details.review-short-version .gloss-term", text: "eager loading")
    expect(opened_term_panel_display).to eq("block")
  end
end
