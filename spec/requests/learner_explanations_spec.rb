require "rails_helper"

RSpec.describe "The explain question on the submitted dashboard", type: :request do
  let(:user) { create_user_with_key(email: "explain@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) } }
  let(:log) { StringIO.new }
  let(:capture) { ActiveSupport::Logger.new(log) }

  before { stub_env("LEARNER_NOTES" => "1") }

  around { |example| travel_to(Time.utc(2026, 11, 18, 15)) { example.run } }

  def default_tags = { "code_review" => "n_plus_one", "pattern" => "service_objects", "challenge" => "callbacks" }

  def submitted_set(owner = user, date: Date.current, tags: default_tags, ratings: {})
    exercise = DailyExercise.create!(
      user: owner, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => tags["code_review"] },
        "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => tags["pattern"] },
        "challenge"   => { "title" => "Build", "question" => "Implement X", "concept" => tags["challenge"] }
      }
    )
    DailyResponse.create!(user: owner, daily_exercise: exercise, date: date,
                          answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "challenge" => "c" * 20 },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level" }.merge(ratings),
                          submitted_at: Time.current,
                          ai_review: %w[code_review pattern challenge].index_with { { "rating" => "solid", "correct" => "Right" } })
    exercise
  end

  def explained(owner, concept, days_ago:)
    exercise = submitted_set(owner, date: Date.current - days_ago, tags: default_tags.merge("code_review" => concept))
    LearnerNote.create!(user: owner, daily_exercise: exercise, explain_section: "code_review", explain_concept: concept,
                        explain_phrasing: "explain.first", explanation: "earlier words")
  end

  def page = Nokogiri::HTML(response.body)
  def box = page.at_css("#learner-explanation")
  def choices = box.css("select option").to_h { |choice| [ choice["value"], choice["data-question"] ] }
  def reply = JSON.parse(response.body)
  def note = LearnerNote.find_by(daily_exercise: user.daily_exercises.for_date.first)

  def save_explanation(text, section: "code_review", **extra)
    post learner_explanation_path, params: { section: section, explanation: text, **extra }, as: :json
  end

  describe "the open box" do
    it "is offered on a day with no duck use and no too-hard rating, below the review, on the first concept" do
      submitted_set
      login_as(user)

      get root_path

      expect(box.at_css(".learner-explanation-question").text).to eq("In your own words, what does N plus one do?")
      expect(box.at_css("select option[selected]")["value"]).to eq("code_review")
      expect(box.at_css("textarea")["maxlength"]).to eq("1000")
      expect(box.at_css("button").text).to eq("Save")
      expect(box.text).to include("Saving sends your explanation, and it can't be changed afterwards.")
      expect(response.body.index("id=\"learner-explanation\"")).to be > response.body.index("id=\"ai-review\"")
    end

    it "lists the day's usable concepts, each with its own wording, in the day's order" do
      submitted_set(tags: default_tags.merge("challenge" => "other"))
      login_as(user)

      get root_path

      expect(box.css("select option").map(&:text)).to eq([ "N plus one", "Service objects" ])
      expect(choices).to eq("code_review" => "In your own words, what does N plus one do?",
                            "pattern" => "In your own words, what does Service objects do?")
    end

    it "opens on a section where the duck was used" do
      exercise = submitted_set(ratings: { "code_review" => "too_hard" })
      DuckThread.create!(user: user, daily_exercise: exercise, draft_scope: exercise.draft_scope,
                         threads: { "pattern" => { "turns" => [ { "role" => "user", "content" => "q" } ], "version" => 1 } })
      login_as(user)

      get root_path

      expect(box.at_css("select option[selected]")["value"]).to eq("pattern")
      expect(box.at_css(".learner-explanation-question").text).to eq("In your own words, what does Service objects do?")
    end

    it "is absent on a day with no usable tag" do
      submitted_set(tags: { "code_review" => "other", "pattern" => nil, "challenge" => "" })
      login_as(user)

      get root_path

      expect(box).to be_nil
    end

    it "is absent before submission, with the setting off and with the switch off" do
      exercise = submitted_set
      exercise.daily_response.update_column(:submitted_at, nil)
      login_as(user)
      get root_path
      expect(box).to be_nil

      exercise.daily_response.update_column(:submitted_at, Time.current)
      user.update!(learner_notes_enabled: false)
      get root_path
      expect(box).to be_nil

      user.update!(learner_notes_enabled: true)
      stub_env("LEARNER_NOTES" => nil)
      get root_path
      expect(box).to be_nil
    end
  end

  describe "phrasing and recency" do
    it "steps a concept explained in the 7 days before aside, but keeps it in the selector with its next wording" do
      explained(user, "n_plus_one", days_ago: 3)
      submitted_set
      login_as(user)

      get root_path

      expect(box.at_css("select option[selected]")["value"]).to eq("pattern")
      expect(choices["code_review"]).to eq("When does N plus one go wrong, or when wouldn't you use it?")
    end

    it "does not count an explanation 8 days back as recent" do
      explained(user, "n_plus_one", days_ago: 8)
      submitted_set
      login_as(user)

      get root_path

      expect(box.at_css("select option[selected]")["value"]).to eq("code_review")
      expect(box.at_css(".learner-explanation-question").text).to eq("When does N plus one go wrong, or when wouldn't you use it?")
    end

    it "counts only the owner's own note rows" do
      teammate = create_user_with_key(email: "teammate@example.com")
      2.times { |back| explained(teammate, "n_plus_one", days_ago: back + 1) }
      submitted_set
      login_as(user)

      get root_path

      expect(box.at_css("select option[selected]")["value"]).to eq("code_review")
      expect(choices["code_review"]).to eq("In your own words, what does N plus one do?")
    end

    it "stores the phrasing the server computes, whatever the page posts" do
      explained(user, "n_plus_one", days_ago: 9)
      explained(user, "n_plus_one", days_ago: 10)
      submitted_set
      login_as(user)

      save_explanation("It loads each row's association with its own query.", explain_phrasing: "explain.first")

      expect(note.explain_phrasing).to eq("explain.third")
    end

    it "lowers the count when an earlier explanation is deleted" do
      earlier = explained(user, "n_plus_one", days_ago: 9)
      submitted_set
      login_as(user)
      earlier.destroy!

      save_explanation("It loads each row's association with its own query.")

      expect(note.explain_phrasing).to eq("explain.first")
    end
  end

  describe "POST /learner_explanation" do
    it "writes nothing about the pick before the save, then the default pick with the text in one save" do
      submitted_set
      login_as(user)
      get root_path
      expect(note).to be_nil

      save_explanation("It runs one query per row.")

      expect(response).to have_http_status(:ok)
      expect(note.attributes.slice("explain_section", "explain_concept", "explain_phrasing", "explanation"))
        .to eq("explain_section" => "code_review", "explain_concept" => "n_plus_one",
               "explain_phrasing" => "explain.first", "explanation" => "It runs one query per row.")
      saved = Nokogiri::HTML(reply["html"]).at_css("#learner-explanation")
      expect(saved.text).to include("In your own words, what does N plus one do?", "It runs one query per row.")
      expect(saved.at_css("textarea, select, button")).to be_nil
    end

    it "stores a different pick's own section and concept" do
      submitted_set
      login_as(user)

      save_explanation("It wraps one operation.", section: "pattern")

      expect(note.explain_section).to eq("pattern")
      expect(note.explain_concept).to eq("service_objects")
    end

    it "refuses a section key outside the options and stores nothing" do
      submitted_set(tags: default_tags.merge("challenge" => "other"))
      login_as(user)

      [ "challenge", "architecture", "" ].each do |section|
        save_explanation("Some words.", section: section)
        expect(response).to have_http_status(:unprocessable_content)
        expect(reply).not_to have_key("html")
      end
      expect(note&.explanation).to be_nil
      expect(note&.explain_section).to be_nil
    end

    it "refuses a blank save and locks nothing" do
      submitted_set
      login_as(user)

      save_explanation("   \n ")
      expect(response).to have_http_status(:unprocessable_content)
      expect(reply["error"]).to eq("Write your explanation before saving.")

      save_explanation("Now with words.")
      expect(response).to have_http_status(:ok)
    end

    it "refuses more than 1,000 characters" do
      submitted_set
      login_as(user)

      save_explanation("a" * 1_001)

      expect(response).to have_http_status(:unprocessable_content)
      expect(note).to be_nil
    end

    it "locks the box on its first save, so a second save is refused and the stored text stays" do
      submitted_set
      login_as(user)
      save_explanation("First words.")

      save_explanation("Second words.", section: "pattern")

      expect(response).to have_http_status(:conflict)
      expect(reply["error"]).to eq("Your explanation is already saved, so it can't change now.")
      expect(note.explanation).to eq("First words.")
      expect(note.explain_section).to eq("code_review")

      get root_path
      expect(box.text).to include("First words.")
      expect(box.at_css("textarea, select, button")).to be_nil
    end

    it "refuses before the day is submitted" do
      exercise = submitted_set
      exercise.daily_response.update_column(:submitted_at, nil)
      login_as(user)

      save_explanation("Too early.")

      expect(response).to have_http_status(:unprocessable_content)
      expect(note).to be_nil
    end

    it "refuses with the setting off" do
      submitted_set
      user.update!(learner_notes_enabled: false)
      login_as(user)

      save_explanation("Off.")

      expect(response).to have_http_status(:not_found)
      expect(note).to be_nil
    end
  end

  describe "the closed box" do
    it "shows the default question and the closed line once the set closed with no explanation, and refuses a save" do
      exercise = submitted_set
      LearnerNote.create!(user: user, daily_exercise: exercise, extracted_at: Time.current)
      login_as(user)

      get root_path

      expect(box.at_css(".learner-explanation-question").text).to eq("In your own words, what does N plus one do?")
      expect(box.text).to include("This question closed at the end of the day you submitted, so there is nothing to save now.")
      expect(box.at_css("textarea, select, button")).to be_nil

      save_explanation("From a tab still open.")

      expect(response).to have_http_status(:conflict)
      expect(reply["error"]).to eq("This question closed at the end of the day you submitted, so there is nothing to save now.")
      expect(Nokogiri::HTML(reply["html"]).at_css("#learner-explanation textarea")).to be_nil
      expect(note.explanation).to be_nil
      expect(note.explain_section).to be_nil
    end
  end

  describe "the log" do
    around do |example|
      Rails.logger.broadcast_to(capture)
      example.run
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end

    it "records whether the pick was the default, with none of the text" do
      submitted_set
      login_as(user)

      save_explanation("a-private-explanation")
      expect(log.string).to include("[learner_explanation] saved pick=default")

      LearnerNote.delete_all
      save_explanation("a-private-explanation", section: "pattern")
      expect(log.string).to include("[learner_explanation] saved pick=different")

      expect(log.string).to match(/"explanation"\s*=>\s*"\[FILTERED\]"/)
      expect(log.string).not_to include("a-private-explanation")
    end
  end
end
