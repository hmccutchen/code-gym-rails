require "rails_helper"

RSpec.describe "A dashboard left open while a newer set arrives", type: :system do
  let(:user) { create_fake_provider_user }

  let(:freshness_checks) { [] }

  def open_dashboard
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i)
    page.execute_script("window.__sameLoad = true")
    page.driver.with_playwright_page do |pw|
      pw.clock.install
      pw.on("request", ->(request) { freshness_checks << request.url if URI(request.url).path == dashboard_freshness_path })
    end
  end

  def let_the_minimum_gap_pass
    gap_ms = Integer(find("[data-controller~='fresh-day']", visible: :all)["data-fresh-day-minimum-gap-value"])
    page.driver.with_playwright_page { |pw| pw.clock.fast_forward(gap_ms + 1000) }
  end

  def move_the_pointer
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(200, 200)
      pw.mouse.move(240, 260)
    end
  end

  def same_load? = page.evaluate_script("window.__sameLoad === true")

  def replace_todays_set
    user.daily_exercises.sole.tap { |exercise| exercise.update!(generated_at: 1.minute.from_now) }.draft_scope
  end

  it "reloads to the newer set once someone is back at the page" do
    travel_to(a_weekday) do
      open_dashboard
      newer_scope = replace_todays_set

      let_the_minimum_gap_pass
      move_the_pointer

      expect(page).to have_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]))
      expect(same_load?).to be(false)
    end
  end

  it "stays on the page when the set has not changed" do
    travel_to(a_weekday) do
      open_dashboard

      let_the_minimum_gap_pass
      move_the_pointer

      wait_for { freshness_checks.size == 1 }
      move_the_pointer
      expect(same_load?).to be(true)
      expect(freshness_checks.size).to eq(1)
    end
  end

  it "sends nothing while nobody is there, however long the page stays open" do
    travel_to(a_weekday) do
      open_dashboard
      replace_todays_set

      let_the_minimum_gap_pass
      let_the_minimum_gap_pass

      expect(same_load?).to be(true)
      expect(freshness_checks).to be_empty
    end
  end

  it "does not check a page that has only just loaded" do
    travel_to(a_weekday) do
      open_dashboard
      replace_todays_set

      move_the_pointer

      expect(same_load?).to be(true)
      expect(freshness_checks).to be_empty
    end
  end
end
