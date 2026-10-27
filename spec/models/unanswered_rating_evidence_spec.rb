require "rails_helper"

# A day that stores a rating on a section nobody answered must give every reader the same result as the day without it.
RSpec.describe "Evidence readers ignore a rating stored on an unanswered section" do
  let(:unanswered_sections) { { "blank" => "", "whitespace-only" => "  \n  ", "scaffold-only" => ExerciseSection::Pattern::DEFAULT_SCAFFOLD.join("\n\n") } }

  def submitted_day(user, written, with_rating:)
    exercise = user.daily_exercises.create!(
      date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "concept" => "n_plus_one", "pitched_at" => "senior", "question" => "q", "snippet" => "s" },
        "pattern"     => { "concept" => "caching", "pitched_at" => "senior", "question" => "q" }
      }
    )
    skipped = with_rating ? { "rating" => "developing", "correct" => "c" } : { "correct" => "c" }
    user.daily_responses.create!(
      daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => written },
      section_ratings: { "code_review" => "right_level" },
      concept_tags: { "code_review" => "n_plus_one", "pattern" => "caching" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => "c", "rubric" => ReviewedSectionResults::RUBRIC_VERSION },
                   "pattern" => skipped }
    )
  end

  def result_for(written, with_rating:)
    user = User.create!(email: "evidence-#{SecureRandom.hex(4)}@example.com", name: "E")
    response = submitted_day(user, written, with_rating: with_rating)
    yield user, response
  end

  # One frozen clock for both runs, or a second boundary between them shows up as a timestamp difference.
  def same_either_way(written)
    results = freeze_time do
      [ true, false ].map { |with_rating| result_for(written, with_rating: with_rating) { |user, response| yield user, response } }
    end
    expect(results.first).to eq(results.last)
  end

  it "leaves the day with its unanswered section outside the answered sections and the submit blocker" do
    same_either_way("") { |_, response| [ response.answered_sections, response.submit_blocker ] }
    expect(result_for("", with_rating: true) { |_, response| response.answered_sections }).to eq([ "code_review" ])
  end

  it "counts a short answer as answered, so its stored rating is evidence" do
    result = result_for("N+1?", with_rating: true) { |_, response| [ response.answered_sections, response.ai_rating_for("pattern") ] }
    expect(result).to eq([ %w[code_review pattern], "developing" ])
  end

  it "gives ConceptMastery.record_review! the same rows" do
    unanswered_sections.each_value do |written|
      same_either_way(written) do |user, response|
        ConceptMastery.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
        user.concept_masteries.order(:concept).map { |cm| cm.attributes.except("id", "user_id", "created_at", "updated_at") }
      end
    end
  end

  it "gives RungLedger the same held and developing rungs" do
    unanswered_sections.each_value do |written|
      same_either_way(written) do |user, _|
        ledger = RungLedger.for(user)
        %w[n_plus_one caching].map { |c| [ ledger.held(c, "ruby_rails"), ledger.developing_toward(c, "ruby_rails") ] }
      end
    end
  end

  it "gives ReviewedSectionResults and recent_performance the same answer" do
    unanswered_sections.each_value do |written|
      same_either_way(written) do |user, response|
        [ ReviewedSectionResults.for(response), user.recent_performance ]
      end
    end
  end
end
