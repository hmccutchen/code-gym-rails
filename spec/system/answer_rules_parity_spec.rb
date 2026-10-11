require "rails_helper"

# Each row runs through the Ruby rule and window.CodeGymAnswerRules on the real dashboard; they must agree.
RSpec.describe "Answer rules in the browser and on the server", type: :system do
  nbsp = " "
  labels = [ "Approach:", "Tradeoffs:" ]

  prose_cases = [
    [ "", [] ], [ "a" * 10, [] ], [ "a" * 11, [] ], [ "#{' ' * 20}abc", [] ], [ "é" * 11, [] ], [ "😀" * 11, [] ],
    [ "\tabcdefghijk\n", [] ], [ "#{nbsp * 6}abcdefgh#{nbsp * 6}", [] ], [ "#{nbsp * 11}", [] ],
    [ "Approach:\nTradeoffs:", labels ], [ "Approach:\nuse a hash map here\nTradeoffs:", labels ],
    [ "  Approach:  \nshort", labels ], [ "Approach:\n#{'x' * 11}", labels ], [ "Approach:\n#{nbsp}Tradeoffs:#{nbsp}", labels ],
    [ "Approach:\n\nTradeoffs:\n#{'y' * 6}\n#{'z' * 5}", labels ],
    [ "abcde#{"\u200B" * 6}", [] ], [ "e\u0301" * 6, [] ], [ "abcde\vfghij", [] ], [ "abcde\u202Efghij", [] ],
    [ "#{"\u{E0041}" * 11}", [] ], [ "Approach:\u200B\n#{'x' * 11}", labels ]
  ]

  comparison_cases = [
    [ "a", "x" * 40 ], [ "a", "x" * 39 ], [ nil, "x" * 50 ], [ "c", "x" * 50 ], [ "b", "  #{'x' * 40}  " ],
    [ "b", "#{nbsp}#{'x' * 39}#{nbsp}" ], [ "a", "😀" * 40 ], [ "a", "#{nbsp * 45}" ],
    [ "a", "#{'x' * 35}#{"\u200B" * 5}" ], [ "b", "e\u0301" * 40 ]
  ]

  blocker_cases = [
    [ [], {} ], [ %w[code_review], {} ], [ %w[code_review], { "code_review" => "right_level" } ],
    [ %w[code_review pattern], { "code_review" => "right_level" } ], [ [], { "code_review" => "too_easy" } ]
  ]

  def rules(call)
    JSON.parse(page.evaluate_script("JSON.stringify(window.CodeGymAnswerRules.#{call})"))
  end

  # The server cleans what it receives before it judges it, so the Ruby side runs that same path.
  def stored(value) = UserText.clean(value, limit: UserText::MAX_ANSWER_LENGTH)

  def ruby_prose_answered(text, case_labels)
    return ExerciseSection::CodeReview.answered?(stored(text)) if case_labels.empty?

    ExerciseSection::Pattern.answered?(stored(text), "answer_scaffold" => case_labels)
  end

  def browser_encoded(pick, reason)
    "#{pick ? "#{ExerciseSection::DesignComparison::PICK_PREFIX}#{pick}" : ''}\n#{reason}"
  end

  def response_with(answered_sections, ratings)
    exercise = DailyExercise.new(user: @user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                                 problem_set: { "code_review" => { "concept" => "n_plus_one" },
                                                "design_comparison" => { "concept" => "open_closed" },
                                                "pattern" => { "concept" => "memoization" } })
    answers = answered_sections.index_with { "a long enough answer" }
    DailyResponse.new(user: @user, daily_exercise: exercise, date: Date.current, answers: answers, section_ratings: ratings)
  end

  it "agrees on every case" do
    travel_to(a_weekday) do
      @user = create_fake_provider_user
      visit_with_todays_set(@user)

      prose_cases.each do |text, case_labels|
        js = rules("proseAnswered(#{text.to_json}, #{case_labels.to_json})")
        expect(js).to eq(ruby_prose_answered(text, case_labels)), "prose #{text.inspect} with #{case_labels.inspect}"
      end

      comparison_cases.each do |pick, reason|
        ruby = ExerciseSection::DesignComparison.answered?(stored(browser_encoded(pick, reason)))
        expect(rules("comparisonAnswered(#{pick.to_json}, #{reason.to_json})")).to eq(ruby), "comparison #{pick.inspect}, #{reason.inspect}"
      end

      blocker_cases.each do |answered_sections, ratings|
        ruby = response_with(answered_sections, ratings).submit_blocker&.to_s
        js = rules("submitBlocker(#{answered_sections.to_json}, #{ratings.to_json})")
        expect(js).to eq(ruby), "blocker #{answered_sections.inspect}, #{ratings.inspect}: browser #{js.inspect}, Ruby #{ruby.inspect}"
      end

      [ [ [], {} ], [ %w[code_review], {} ], [ %w[code_review], { "code_review" => "right_level" } ] ].each do |answered_sections, ratings|
        response = response_with(answered_sections, ratings)
        ruby = ApplicationController.helpers.section_status(response, "code_review")
        label = response.self_rating_label("code_review")
        in_progress = I18n.t("responses.section_status.in_progress")
        js = rules("sectionStatus(#{response.answered?('code_review')}, #{label.to_json}, #{in_progress.to_json})")
        expect(js).to eq(ruby), "status #{answered_sections.inspect}, #{ratings.inspect}"
      end

      expect(rules("PARSONS_PREFIX")).to eq(ExerciseSection::ParsonsProblem::ANSWER_PREFIX)
    end
  end
end
