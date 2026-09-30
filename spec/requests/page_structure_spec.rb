require "rails_helper"

# What a screen reader navigates by: the main landmark and the link to it,
# headings that never skip a level, and a name on every text field.
RSpec.describe "Page structure for assistive technology", type: :request do
  let(:user) { create_user_with_key }

  def doc
    Nokogiri::HTML(response.body)
  end

  def heading_levels
    doc.css("h1, h2, h3, h4, h5, h6").map { |h| h.name[1].to_i }
  end

  def skipped_levels
    heading_levels.each_cons(2).select { |before, after| after > before + 1 }
  end

  def label_for(input)
    doc.at_css(%(label[for="#{input["id"]}"]))
  end

  def reviewed_day(date:, submitted_at: Time.current)
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
        "pattern" => { "title" => "Service Objects", "question" => "When?" }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20 },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
      submitted_at: submitted_at,
      ai_review: {
        "code_review" => { "rating" => "solid", "correct" => "Good catch" },
        "pattern" => { "rating" => "developing", "correct" => "Right idea" }
      }
    )
  end

  before { login_as(user) }

  it "wraps the page in one main landmark that the first link skips to" do
    get learn_path

    expect(doc.css("main").size).to eq(1)
    expect(doc.at_css("main")["id"]).to eq("main-content")
    expect(doc.at_css("body a")).to have_attributes(text: "Skip to content")
    expect(doc.at_css("body a")["href"]).to eq("#main-content")
  end

  it "keeps the main landmark inside the area pull-to-refresh moves" do
    get learn_path

    expect(doc.at_css("[data-pull-content] > main")).to be_present
  end

  it "does not skip a heading level on the submitted dashboard" do
    travel_to(Date.new(2026, 7, 15)) do
      reviewed_day(date: Date.current)
      get root_path
    end

    expect(doc.at_css("h2").text).to include("Review")
    expect(doc.css(".review-block h3").size).to eq(2)
    expect(skipped_levels).to be_empty
  end

  it "does not skip a heading level in History" do
    reviewed_day(date: 1.day.ago.to_date)
    get history_path

    expect(doc.css(".review-block h3").size).to eq(2)
    expect(skipped_levels).to be_empty
  end

  it "labels the follow-up field with a real label, not only its placeholder" do
    reviewed_day(date: 1.day.ago.to_date)
    get history_path

    inputs = doc.css("input.follow-up-input")
    expect(inputs.size).to eq(2)
    expect(inputs.map { |input| input["id"] }.uniq.size).to eq(2)
    inputs.each { |input| expect(label_for(input)&.text).to eq("Ask a follow-up about this feedback") }
  end

  it "labels the duck's field with a real label, not only its placeholder" do
    travel_to(Date.new(2026, 7, 15)) do
      reviewed_day(date: Date.current, submitted_at: nil)
      get root_path
    end

    inputs = doc.css("input.duck-input")
    expect(inputs.size).to eq(2)
    inputs.each { |input| expect(label_for(input)&.text).to eq("What are you stuck on?") }
  end

  it "reads each Exercise mix slider's value as its stop word" do
    user.update!(section_kind_weights: { "challenge" => KindPreferences::MULTIPLIERS.first })
    get setup_path

    expect(doc.at_css("#weight-challenge")["aria-valuetext"]).to eq(I18n.t("exercise_mix.stops").first)
    expect(doc.at_css("#weight-architecture")["aria-valuetext"]).to eq("Default")
  end
end
