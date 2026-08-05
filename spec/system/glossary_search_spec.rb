require "rails_helper"

RSpec.describe "Glossary search on the dashboard", type: :system do
  it "looks up a known term, flags an unknown term, and stacks results in one section" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_dup
      )
      visit_as(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      box = find("[data-glossary-search][data-field='code_review']")

      box.find("input[type='text']").fill_in(with: "closure")
      box.find("button").click
      expect(box).to have_css(".glossary-results li", count: 1)
      expect(box).to have_content("closure: #{Glossary::TERMS['closure']}")

      box.find("input[type='text']").fill_in(with: "not-a-real-term")
      box.find("button").click
      expect(box).to have_css(".glossary-results li", count: 2)
      expect(box).to have_css(".glossary-results li.glossary-miss",
        text: /"not-a-real-term" isn't in the glossary yet/)
    end
  end
end
