require "rails_helper"

RSpec.describe "Changing the track on Setup", type: :system, with_csrf: true do
  let(:user) do
    create_fake_provider_user.tap do |user|
      user.update_columns(skill_level: "junior",
                          section_kind_levels: ExerciseSection.keys.index_with { "junior" }.merge("pattern" => "senior"),
                          locked_section_kinds: [ "challenge" ])
      DailyExercise.create!(user: user, date: Date.yesterday, generated_at: 1.day.ago,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
    end
  end

  def wait_for(timeout)
    deadline = Time.current + timeout
    sleep 0.1 until yield || Time.current > deadline
  end

  def checked_level(kind)
    find(".mix-difficulty[data-kind='#{kind}'] input[type=radio]:checked", visible: :all).value
  end

  it "updates the Exercise mix without a reload, names the kept sections, and lets the next mix edit save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script("window.sameDocument = true")

    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern")
    expect(find('[data-profile-preferences-target="keptOwnLevel"]').text).to include("Senior", "Junior, locked")
    expect(checked_level("code_review")).to eq("")
    expect(checked_level("pattern")).to eq("senior")
    expect(checked_level("challenge")).to eq("junior")
    expect(user.reload.section_kind_levels).to eq("pattern" => "senior", "challenge" => "junior")

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click

    expect(page).to have_no_css("#save-status", text: /changed in another tab/i, wait: 2)
    expect(page).to have_css(".mix-difficulty[data-kind='code_review'] input[value='senior']:checked", visible: :all)
    wait_for(5) { user.reload.section_kind_levels["code_review"] == "senior" }
    expect(user.reload.section_kind_levels).to include("code_review" => "senior")
    expect(page.evaluate_script("window.sameDocument")).to be(true)
  end

  def guide_measurement
    page.evaluate_script(<<~JS)
      (() => {
        const guide = document.querySelector(".key-guide");
        const style = getComputedStyle(guide.querySelector(".hint"));
        return { fontSize: style.fontSize, documentWidth: document.documentElement.scrollWidth };
      })()
    JS
  end

  it "measures the key guide at phone width without hiding content or shrinking type" do
    fresh = User.create!(email: "keyless-#{SecureRandom.hex(3)}@example.com", name: "Keyless", **chosen_track(true))
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    visit_as(fresh)
    visit setup_path
    expect(page).to have_css(".key-guide")

    [ "100", "125", "140" ].each do |size|
      fresh.update!(display_preferences: size == "100" ? {} : { "text_size" => size })
      visit setup_path
      measurement = guide_measurement
      expect(measurement["documentWidth"]).to be <= 390
      expect(measurement["fontSize"].to_f).to be >= 12.8
      expect(page).to have_css(".key-guide li", count: 12)
      expect(page).to have_css(".key-guide p", text: "What it costs.")
    end
  end
end
