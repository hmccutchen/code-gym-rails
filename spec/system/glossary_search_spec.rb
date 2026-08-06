require "rails_helper"

RSpec.describe "Glossary search on the dashboard", type: :system do
  it "looks up a known term, flags an unknown term, and replaces the prior result on a new search" do
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
      box.find("button", text: "Search").click
      expect(box).to have_css(".glossary-results li", count: 1)
      expect(box).to have_content("closure: #{Glossary::TERMS['closure']}")

      box.find("input[type='text']").fill_in(with: "not-a-real-term")
      box.find("button", text: "Search").click
      expect(box).to have_css(".glossary-results li", count: 1)
      expect(box).to have_css(".glossary-results li.glossary-miss",
        text: /"not-a-real-term" isn't in the glossary yet/)
      expect(box).to have_no_content("closure:")
    end
  end

  it "clears a section's result and input without affecting other sections" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_dup
      )
      visit_as(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      box = find("[data-glossary-search][data-field='code_review']")
      other_box = find("[data-glossary-search][data-field='pattern']")

      box.find("input[type='text']").fill_in(with: "closure")
      box.find("button", text: "Search").click
      expect(box).to have_css(".glossary-results li", count: 1)

      other_box.find("input[type='text']").fill_in(with: "closure")
      other_box.find("button", text: "Search").click
      expect(other_box).to have_css(".glossary-results li", count: 1)

      box.find("button", text: "Clear").click

      expect(box).to have_no_css(".glossary-results li")
      expect(box.find("input[type='text']").value).to eq("")
      expect(other_box).to have_css(".glossary-results li", count: 1)
    end
  end

  it "clears an empty section without error" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_dup
      )
      visit_as(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      box = find("[data-glossary-search][data-field='code_review']")

      box.find("button", text: "Clear").click

      expect(box).to have_no_css(".glossary-results li")
      expect(box.find("input[type='text']").value).to eq("")
    end
  end

  it "submits on Enter without submitting the surrounding answers form, and scopes results to the searched box" do
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
      box.find("input[type='text']").send_keys(:enter)

      expect(box).to have_css(".glossary-results li", count: 1)
      expect(box).to have_content("closure: #{Glossary::TERMS['closure']}")
      expect(page).to have_css("#gym-form")

      other_box = find("[data-glossary-search][data-field='pattern']")
      expect(other_box).to have_no_css(".glossary-results li")
    end
  end
end
