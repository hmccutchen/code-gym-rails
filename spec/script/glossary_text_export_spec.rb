require "rails_helper"
require Rails.root.join("script/glossary_text_export")
require Rails.root.join("script/glossary_sense_listing_report")

RSpec.describe GlossaryTextExport do
  let(:user) { User.create!(email: "glossary-export@example.com") }
  let(:out) { StringIO.new }
  let(:sections) do
    { "code_review" => { "scenario" => "A webhook retries.", "question" => "What's wrong?" },
      "architecture" => { "question" => "Which design?", "options" => [ "A queue", "A cron job" ],
                         "reference" => { "tagline" => "Queue the work.", "explanation" => "A worker drains it.",
                                          "tradeoffs" => [ "More moving parts." ], "senior_lens" => "Watch the backlog.",
                                          "diagram" => "flowchart TD\n  DIAGRAM-SENTINEL" } },
      "ambiguity_hunt" => { "question" => "What's unclear?", "request" => "Add a callback after save." },
      "pseudocode_to_code" => { "question" => "Write it.", "problem_statement" => "Sum the totals." },
      "pattern" => { "question" => "Which pattern?", "why" => "A service object keeps the controller thin." },
      "plan_review" => { "question" => "What's missing?", "plan_excerpt" => "Step 1: add a callback.",
                         "answer_key" => { "issue" => "KEY-SENTINEL" } },
      "security_review" => { "question" => "What's exposed?", "planted_ambiguities" => [ "AMBIGUITY-SENTINEL" ] } }
  end

  def reviewed_day
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails", problem_set: sections)
    user.daily_responses.create!(
      daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "an answer" }, section_ratings: { "code_review" => "right_level" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => [ "You found the callback." ], "missed" => "The ref.",
                                      "better_questions" => [], "next_step" => "Try a hook.",
                                      "difficulty" => { "level" => "moderate", "reason" => "It needs a model hook." } } },
      review_alternates: { "code_review" => [ "Another way: an after_save hook." ] }
    )
  end

  def rows = out.string.lines.map { |line| JSON.parse(line) }

  it "writes every glossary-wrapped piece of review and exercise text as one JSONL row each" do
    response = reviewed_day

    described_class.new(out: out).call

    review_id = "#{response.id}:code_review"
    exercise_id = response.daily_exercise_id
    expect(rows).to contain_exactly(
      { "source" => "review", "id" => review_id, "field" => "correct", "text" => "You found the callback." },
      { "source" => "review", "id" => review_id, "field" => "missed", "text" => "The ref." },
      { "source" => "review", "id" => review_id, "field" => "next_step", "text" => "Try a hook." },
      { "source" => "review", "id" => review_id, "field" => "difficulty_reason", "text" => "It needs a model hook." },
      { "source" => "review", "id" => review_id, "field" => "alternate", "text" => "Another way: an after_save hook." },
      { "source" => "exercise", "id" => "#{exercise_id}:code_review", "field" => "scenario", "text" => "A webhook retries." },
      { "source" => "exercise", "id" => "#{exercise_id}:code_review", "field" => "question", "text" => "What's wrong?" },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "question", "text" => "Which design?" },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "option", "text" => "A queue" },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "option", "text" => "A cron job" },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "reference_tagline", "text" => "Queue the work." },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "reference_explanation", "text" => "A worker drains it." },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "reference_tradeoff", "text" => "More moving parts." },
      { "source" => "exercise", "id" => "#{exercise_id}:architecture", "field" => "reference_senior_lens", "text" => "Watch the backlog." },
      { "source" => "exercise", "id" => "#{exercise_id}:ambiguity_hunt", "field" => "question", "text" => "What's unclear?" },
      { "source" => "exercise", "id" => "#{exercise_id}:ambiguity_hunt", "field" => "request", "text" => "Add a callback after save." },
      { "source" => "exercise", "id" => "#{exercise_id}:pseudocode_to_code", "field" => "question", "text" => "Write it." },
      { "source" => "exercise", "id" => "#{exercise_id}:pseudocode_to_code", "field" => "problem_statement", "text" => "Sum the totals." },
      { "source" => "exercise", "id" => "#{exercise_id}:pattern", "field" => "question", "text" => "Which pattern?" },
      { "source" => "exercise", "id" => "#{exercise_id}:pattern", "field" => "why", "text" => "A service object keeps the controller thin." },
      { "source" => "exercise", "id" => "#{exercise_id}:plan_review", "field" => "question", "text" => "What's missing?" },
      { "source" => "exercise", "id" => "#{exercise_id}:plan_review", "field" => "plan_excerpt", "text" => "Step 1: add a callback." },
      { "source" => "exercise", "id" => "#{exercise_id}:security_review", "field" => "question", "text" => "What's exposed?" }
    )
  end

  it "leaves out the answer, rating, answer key and user columns" do
    reviewed_day

    described_class.new(out: out).call

    expect(out.string).not_to include("an answer", "solid", "right_level", "glossary-export@example.com", "KEY-SENTINEL", "AMBIGUITY-SENTINEL")
  end

  it "reads inside a read-only transaction" do
    reviewed_day
    allow(ReviewBaselineExport).to receive(:read_only).and_call_original

    described_class.new(out: out).call

    expect(ReviewBaselineExport).to have_received(:read_only)
  end

  it "writes rows the glossary sense listing reads" do
    reviewed_day
    described_class.new(out: out).call
    path = Rails.root.join("tmp/glossary_text_export_spec_#{Process.pid}.jsonl")
    File.write(path, out.string)

    expect(GlossarySenseListingReport.read_rows(path).size).to eq(rows.size)
  ensure
    FileUtils.rm_f(path) if path
  end
end
