require "rails_helper"

RSpec.describe "The design comparison section", type: :request do
  let(:user) { create_user_with_key }
  let(:reason) { "A new carrier arrives every month, so the registry never edits working code." }
  let(:comparison) do
    {
      "title" => "Where shipping rates come from",
      "scenario" => "The team adds a carrier every month.",
      "question" => "Which piece fits?",
      "piece_a" => "class OtherPiece\nend",
      "piece_b" => "class BetterPiece\nend",
      "answer_key" => { "better" => "b", "deciding_fact" => "SECRET deciding fact",
                        "principle" => "SECRET principle", "why_other_fails" => "SECRET other cost" },
      "concept" => "open_closed"
    }
  end
  let!(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
                                         "design_comparison" => comparison })
  end

  before { login_as(user) }

  def page
    Nokogiri::HTML(response.body)
  end

  context "before submission" do
    it "shows each piece in its own open disclosure" do
      get root_path

      pieces = page.css("details.comparison-piece[open]")
      expect(pieces.map { |piece| piece.at_css("summary").text.strip }).to eq([ "Piece A", "Piece B" ])
      expect(pieces.map { |piece| code_block_text(piece.at_css("code.highlight")) }).to eq([ "class OtherPiece\nend", "class BetterPiece\nend" ])
    end

    it "asks for the pick as a labelled radio group and the reason in a labelled textarea" do
      get root_path

      fieldset = page.at_css("fieldset.comparison-pick")
      expect(fieldset.at_css("legend").text).to eq("Which piece fits this system better?")
      expect(fieldset.css("input[type=radio]").map { |radio| radio["value"] }).to eq(%w[a b])
      reason_box = page.at_css("textarea[data-comparison-reason]")
      expect(page.at_css("label[for='#{reason_box['id']}']").text).to eq("What decides it?")
    end

    it "keeps the stored answer in one hidden field the shared gate reads" do
      get root_path

      field = page.at_css("textarea[data-field='design_comparison']")
      expect(field["name"]).to eq("response[answers][design_comparison]")
      expect(field["data-answer-complete"]).to eq("false")
      expect(page.css("textarea[data-field]").map { |t| t["data-field"] }).to eq(%w[code_review design_comparison])
    end

    it "restores a saved pick and reason, and marks a complete one complete" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "design_comparison" => "pick:b\n#{reason}" })

      get root_path

      expect(page.at_css("input[type=radio][value=b]")["checked"]).to be_present
      expect(page.at_css("input[type=radio][value=a]")["checked"]).to be_nil
      expect(page.at_css("textarea[data-comparison-reason]").text.strip).to eq(reason)
      expect(page.at_css("textarea[data-field='design_comparison']")["data-answer-complete"]).to eq("true")
    end

    # The reference illustrates the principle the grade asks for, so opening it would give away the reason.
    it "keeps the concept reference closed on first exposure, where another kind opens it" do
      exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "concept" => "n_plus_one" }))
      %w[open_closed n_plus_one].each do |concept|
        ConceptReference.create!(concept: concept, language: "ruby_rails", tagline: "t", explanation: "e",
                                 code_example: "c", senior_lens: "l")
      end

      get root_path

      expect(response.body).to match(/<details class="ref" open>\s*<summary>Reference — N plus one: how it works/)
      expect(response.body).to match(/<details class="ref">\s*<summary>Reference — Open closed: how it works/)
    end

    it "never puts the answer key in the page" do
      get root_path

      expect(response.body).not_to include("SECRET")
      expect(response.body).not_to include("What decides it</h3>")
    end
  end

  context "once submitted" do
    it "replays the pick and the reason, and still withholds the key until the section is reviewed" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                            answers: { "design_comparison" => "pick:b\n#{reason}" })

      get root_path

      expect(response.body).to include("Picked piece B", reason)
      expect(response.body).not_to include("SECRET")
    end

    it "shows what decides it once the section has been reviewed" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                            answers: { "design_comparison" => "pick:a\n#{reason}" },
                            ai_review: { "design_comparison" => { "rating" => "developing", "correct" => [], "missed" => [] } })

      get root_path

      key = page.at_css(".comparison-key")
      expect(key.at_css("h3").text).to eq("What decides it")
      expect(key.text).to include("Piece B is the better fit.", "SECRET deciding fact", "SECRET principle", "SECRET other cost")
    end
  end
end
