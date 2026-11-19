require "rails_helper"

RSpec.describe "PATCH /learner_note", type: :request do
  let(:user) { create_user_with_key(email: "notes@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) } }
  let(:log) { StringIO.new }
  let(:capture) { ActiveSupport::Logger.new(log) }

  before { stub_env("LEARNER_NOTES" => "1") }

  def create_exercise_for(owner)
    DailyExercise.create!(
      user: owner, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => "service_objects" },
        "challenge"   => { "title" => "Build", "question" => "Implement X", "concept" => "other" }
      }
    )
  end

  def save_note(text, scope: user.daily_exercises.for_date.first&.draft_scope)
    patch learner_note_path, params: { learner_note: text, draft_scope: scope }, as: :json
  end

  def note = LearnerNote.find_by(daily_exercise: user.daily_exercises.for_date.first)
  def reply = JSON.parse(response.body)

  it "autosaves the note and answers with the question the box shows" do
    create_exercise_for(user)
    login_as(user)

    save_note("I couldn't see where the query ran.")

    expect(response).to have_http_status(:ok)
    expect(reply).to eq("status" => "ok", "question" => "What was the hardest part of today's set?", "question_key" => "hardest")
    expect(note.body).to eq("I couldn't see where the query ran.")
    expect(note.user).to eq(user)
  end

  it "fixes the question on the first non-blank save, so a later signal does not change it" do
    exercise = create_exercise_for(user)
    login_as(user)

    save_note("   ")
    expect(note.question_key).to be_nil

    save_note("The loop confused me.")
    expect(note.question_key).to eq("hardest")

    DuckThread.append!(exercise, "code_review", message: "q", answer: "a", expected_version: 0, expected_scope: exercise.draft_scope)
    save_note("The loop confused me, still.")

    expect(note.question_key).to eq("hardest")
    expect(reply["question"]).to eq("What was the hardest part of today's set?")
  end

  it "picks the question from the day's own signals before the first save" do
    exercise = create_exercise_for(user)
    DuckThread.append!(exercise, "pattern", message: "q", answer: "a", expected_version: 0, expected_scope: exercise.draft_scope)
    login_as(user)

    save_note("Still lost.")

    expect(note.question_key).to eq("duck_turns:pattern")
    expect(reply["question"]).to eq("You asked the thinking partner about Pattern of the Month. What was unclear at first?")
  end

  describe "the question the page showed" do
    def shown_box = Nokogiri::HTML(response.body).at_css("#learner-note")

    it "is rendered on the box as its key, and stored even after a duck turn between render and first save" do
      exercise = create_exercise_for(user)
      login_as(user)
      get root_path
      expect(shown_box.at_css("[data-learner-note-target=question]").text).to eq("What was the hardest part of today's set?")
      expect(shown_box["data-learner-note-question-key-value"]).to eq("hardest")

      DuckThread.append!(exercise, "pattern", message: "q", answer: "a", expected_version: 0, expected_scope: exercise.draft_scope)
      patch learner_note_path, params: { learner_note: "The loop confused me.", draft_scope: exercise.draft_scope,
                                         question_key: "hardest" }, as: :json

      expect(note.question_key).to eq("hardest")
      expect(reply).to include("question" => "What was the hardest part of today's set?", "question_key" => "hardest")
    end

    it "falls back to the server's pick for a key that is not a real question or names a section the set lacks" do
      exercise = create_exercise_for(user)
      DuckThread.append!(exercise, "pattern", message: "q", answer: "a", expected_version: 0, expected_scope: exercise.draft_scope)
      login_as(user)

      patch learner_note_path, params: { learner_note: "Lost.", draft_scope: exercise.draft_scope, question_key: "made_up" }, as: :json
      expect(note.question_key).to eq("duck_turns:pattern")

      note.update!(question_key: nil)
      patch learner_note_path, params: { learner_note: "Lost.", draft_scope: exercise.draft_scope,
                                         question_key: "duck_turns:security_review" }, as: :json
      expect(note.question_key).to eq("duck_turns:pattern")
    end
  end

  it "keeps at most 1,000 characters" do
    create_exercise_for(user)
    login_as(user)

    save_note("a" * 1_200)

    expect(response).to have_http_status(:ok)
    expect(note.body.length).to eq(1_000)
  end

  it "refuses a page showing another set, as the duck does, and stores nothing" do
    create_exercise_for(user)
    login_as(user)

    save_note("from an old tab", scope: "1-1")

    expect(response).to have_http_status(:conflict)
    expect(reply["status"]).to eq("error")
    expect(note).to be_nil
  end

  describe "the conflict reply's banner sentence" do
    def save_to_replaced_set
      exercise = create_exercise_for(user)
      shown_scope = exercise.draft_scope
      exercise.update!(generated_at: 1.minute.from_now)
      login_as(user)
      save_note("for the replaced set", scope: shown_scope)
      expect(response).to have_http_status(:conflict)
    end

    it "carries the sentence the server picks with STALE_SET_BANNER on" do
      stub_env("STALE_SET_BANNER" => "1")

      save_to_replaced_set

      expect(reply["banner"]).to eq(I18n.t("dashboard.stale_set.replaced"))
      expect(note).to be_nil
    end

    it "has no banner key with STALE_SET_BANNER off" do
      save_to_replaced_set

      expect(reply).to eq("status" => "error", "error" => I18n.t("flash.responses.stale_answers"))
    end
  end

  it "is read-only once the day is submitted" do
    exercise = create_exercise_for(user)
    login_as(user)
    save_note("before submit")
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "answer" }, section_ratings: { "code_review" => "right_level" },
                          submitted_at: Time.current)

    save_note("after submit")

    expect(response).to have_http_status(:unprocessable_content)
    expect(reply["error"]).to eq("This set is submitted, so its note can't change now.")
    expect(reply["submitted"]).to be(true)
    expect(note.body).to eq("before submit")
  end

  it "refuses with no set today" do
    login_as(user)

    save_note("nothing to attach to", scope: "")

    expect(response).to have_http_status(:not_found)
    expect(LearnerNote.count).to eq(0)
  end

  it "refuses while the account's setting is off" do
    create_exercise_for(user)
    user.update!(learner_notes_enabled: false)
    login_as(user)

    save_note("off")

    expect(response).to have_http_status(:not_found)
    expect(LearnerNote.count).to eq(0)
  end

  it "refuses while LEARNER_NOTES is off" do
    create_exercise_for(user)
    stub_env("LEARNER_NOTES" => nil)
    login_as(user)

    save_note("off")

    expect(response).to have_http_status(:not_found)
    expect(LearnerNote.count).to eq(0)
  end

  describe "the box on the dashboard" do
    def box = Nokogiri::HTML(response.body).at_css("#learner-note")

    it "shows the picked question and the stored note below the sections, saving through its own controller" do
      exercise = create_exercise_for(user)
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "earlier words")
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, section_ratings: { "pattern" => "too_hard" })
      login_as(user)

      get root_path

      expect(box["data-controller"]).to eq("learner-note")
      expect(box.at_css("label").text).to eq("You rated Pattern of the Month too hard. Which part did you get stuck on?")
      expect(box.at_css("textarea").text).to eq("earlier words")
      expect(box.at_css("textarea")["maxlength"]).to eq("1000")
      expect(box.ancestors("form")).to be_empty
    end

    it "asks about a section passed over for a later one" do
      exercise = create_exercise_for(user)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "pattern" => "an answer" })
      login_as(user)

      get root_path

      expect(box.at_css("label").text).to eq("You skipped Code Review. What would you have needed to start it?")
    end

    it "shows the note read-only on the submitted day, under the question it was written to" do
      exercise = create_exercise_for(user)
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "kept words", question_key: "hardest")
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "answer" },
                            section_ratings: { "code_review" => "too_hard" }, submitted_at: Time.current)
      login_as(user)

      get root_path

      expect(box["data-controller"]).to be_nil
      expect(box.at_css("textarea")).to be_nil
      expect(box.text).to include("What was the hardest part of today's set?", "kept words")
    end

    it "shows nothing while the setting is off, or with the switch off" do
      create_exercise_for(user)
      login_as(user)
      user.update!(learner_notes_enabled: false)
      get root_path
      expect(box).to be_nil

      user.update!(learner_notes_enabled: true)
      stub_env("LEARNER_NOTES" => "0")
      get root_path
      expect(box).to be_nil
    end
  end

  describe "the log" do
    around do |example|
      Rails.logger.broadcast_to(capture)
      example.run
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end

    it "carries none of the note's text" do
      create_exercise_for(user)
      login_as(user)

      save_note("a-private-stuck-point")

      expect(log.string).to match(/"learner_note"\s*=>\s*"\[FILTERED\]"/)
      expect(log.string).not_to include("a-private-stuck-point")
    end
  end
end
