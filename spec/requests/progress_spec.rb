require "rails_helper"

RSpec.describe "Progress", type: :request do
  let(:user) { create_user_with_key }

  before do
    user.update!(language: "ruby_rails")
    login_as(user)
  end

  def reviewed_session(date:, concept:, rung:, section: "code_review", self_rating: "right_level", ai_rating: "solid")
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { section => { "question" => "q", "concept" => concept, "pitched_at" => rung } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
                          answers: { section => "x" * 20 }, section_ratings: { section => self_rating },
                          concept_tags: { section => concept }, ai_review: { section => { "rating" => ai_rating } })
  end

  it "groups concepts exactly as the Learn tab does and links each to its Learn page" do
    get progress_path

    expect(response).to have_http_status(:ok)
    ConceptGroup::NAMED.map(&:first).each { |group| expect(response.body).to include(I18n.t("learn.groups.#{group}")) }
    expect(response.body).to include(learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one"))
  end

  it "shows the rung a concept is held at, and not yet for the rest" do
    reviewed_session(date: Date.current - 1, concept: "n_plus_one", rung: "senior")

    get progress_path

    expect(response.body).to match(%r{data-concept="n_plus_one"[^>]*data-standing="senior"})
    expect(response.body).to match(%r{data-concept="memoization"[^>]*data-standing="not_yet"})
  end

  it "summarizes each group by rung counts rather than a percentage" do
    reviewed_session(date: Date.current - 1, concept: "n_plus_one", rung: "senior")

    get progress_path

    page = Nokogiri::HTML(response.body)
    page.css("style, script").remove
    visible = page.text

    expect(visible).to include("1 senior")
    expect(visible).not_to match(/\d+\s*%/)
    expect(visible.downcase).not_to include("streak")
  end

  it "words a concept no offered section can show as the user's choice, with a way to Setup" do
    user.update!(excluded_section_kinds: [ "architecture" ])

    get progress_path

    expect(response.body).to match(%r{data-concept="sync_vs_async"[^>]*data-standing="not_offered"})
    expect(response.body).to include("not offered")
    expect(response.body).to include(setup_path)
  end

  it "appears in the navigation" do
    get root_path

    expect(response.body).to include(progress_path)
  end
end
