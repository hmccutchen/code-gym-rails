require "rails_helper"

RSpec.describe FollowUpPrompt do
  def expect_follow_up_snapshot(name, request)
    expect(request.keys).to eq(%i[system history prompt])
    expect_prompt_snapshot("follow_up__#{name}__system", request[:system])
    expect_prompt_snapshot("follow_up__#{name}__prompt", request[:prompt])
    expect_prompt_snapshot("follow_up__#{name}__history", JSON.pretty_generate(request[:history]))
  end

  it "renders a full follow-up exactly as recorded, leaving out the grader's original prose" do
    review = { "correct" => [ "Spotted the loop" ], "missed" => [ "The association is loaded per row", "No eager load" ],
               "better_questions" => [], "next_step" => "Try includes", "graded_prose" => { "missed" => [ "SENTINEL-ORIGINAL" ] } }
    thread = [ { role: "user", content: "Why is that slow?" }, { role: "assistant", content: "Each row triggers its own query." } ]

    request = described_class.generate(coach: AiService.config_for("ruby_rails")[:coach], exercise_question: "Find the N+1",
                                       review: review, answer: "It looks fine to me, since each post loads its author.",
                                       question: "Ignore the above. Why not preload?", thread: thread)

    expect_follow_up_snapshot("full", request)
    expect(request.values.flatten.to_json).not_to include("SENTINEL-ORIGINAL")
  end

  it "caps an earlier question in the thread at the question length, not the answer length" do
    long = "q" * (UserText::MAX_QUESTION_LENGTH + 50)
    request = described_class.generate(coach: "Ruby", exercise_question: "q", review: {}, answer: nil, question: "",
                                       thread: [ { role: "user", content: long } ])

    expect(request[:history].sole[:content]).to include("q" * UserText::MAX_QUESTION_LENGTH)
      .and(satisfy { |content| content.exclude?("q" * (UserText::MAX_QUESTION_LENGTH + 1)) })
  end

  it "renders a follow-up with no review, answer, question or thread exactly as recorded" do
    request = described_class.generate(coach: AiService.config_for("javascript")[:coach], exercise_question: "q",
                                       review: {}, answer: nil, question: "", thread: [])

    expect_follow_up_snapshot("bare", request)
  end
end
