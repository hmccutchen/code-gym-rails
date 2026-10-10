require "rails_helper"

RSpec.describe "Parsons reorder controls", type: :system do
  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # FakeService always loses parsons_problem to architecture in DailyPlan's precedence, so seed it directly.
  def seed_parsons_exercise
    DailyExercise.create!(
      user: user,
      date: weekday.to_date,
      language: "ruby_rails",
      generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one",
          "teaching_note" => "Start with what has to exist first."
        }
      }
    )
  end

  SORTABLE_URL = "**cdn.jsdelivr.net**sortable**"

  # Intercepting the CDN request makes both fallback branches testable regardless of the runner's network.
  def stub_sortable_cdn(outcome)
    page.driver.with_playwright_page do |pw|
      pw.route(SORTABLE_URL, ->(route, _request) {
        case outcome
        when :blocked then route.abort
        when :loaded  then route.fulfill(
          status: 200,
          contentType: "application/javascript",
          body: "export default { create() {} };"
        )
        end
      })
    end
  end

  def visit_seeded_dashboard(cdn:)
    seed_parsons_exercise
    stub_sortable_cdn(cdn)
    visit_as(user)
    expect(page).to have_css("ol[data-parsons-blocks][data-parsons-wired]", wait: 10)
  end

  # The page shows opaque tokens, so read the arrangement back through the server's own decoding.
  def block_positions
    exercise = user.daily_exercises.sole
    ExerciseSection::ParsonsProblem.token_ids(
      exercise: exercise, key: "parsons_problem",
      section_data: exercise.problem_set["parsons_problem"]
    )
  end

  def block_ids
    positions = block_positions
    all("ol[data-parsons-blocks] .parsons-block").map { |li| positions[li["data-block-id"]].to_s }
  end

  def hidden_answer
    value = find("textarea[data-field='parsons_problem']", visible: :all).value
    ExerciseSection::ParsonsProblem.decode_answer(
      value, exercise: user.daily_exercises.sole, key: "parsons_problem",
      section_data: user.daily_exercises.sole.problem_set["parsons_problem"]
    )
  end

  [ 1, 2, 3 ].each do |count|
    it "counts an explicitly chosen #{count}-block arrangement, but not an untouched one", with_csrf: true do
      travel_to(weekday) do
        exercise = seed_parsons_exercise
        exercise.problem_set["parsons_problem"].merge!(
          "blocks" => Array.new(count) { |i| "block #{i}" }, "display_order" => (0...count).to_a
        )
        exercise.save!
        stub_sortable_cdn(:loaded)
        visit_as(user)

        expect(page).to have_content("0 of 3 answered")
        expect(hidden_answer).to be_empty
        expect(page).to have_no_css('.hint-slot[data-hint-for="parsons_problem"] > details')
        expect(page).to have_button("Submit answers", disabled: true)
        rate_section("parsons_problem")
        expect(page).to have_button("Submit answers", disabled: true)
        if count == 1
          click_button "Use this order"
        else
          expect(page).to have_no_button("Use this order")
          find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys([ :control, :down ])
        end

        expect(page).to have_content("1 of 3 answered")
        expect(page).to have_css('.hint-slot[data-hint-for="parsons_problem"] > details.hint')
        expect(page).to have_button("Submit answers", disabled: false)
        Timeout.timeout(10) do
          sleep 0.05 until user.daily_responses.reload.first&.answered?("parsons_problem")
        end
        visit root_path
        expect(page).to have_content("1 of 3 answered")
        expect(page).to have_button("Submit answers", disabled: false)
        click_button "Submit answers"
        expect(page).to have_content("Review ready!", wait: 10)
        expect(user.daily_responses.reload.sole.section_ratings).to eq("parsons_problem" => "right_level")
      end
    end

    it "counts a saved #{count}-block arrangement when the form loads" do
      travel_to(weekday) do
        exercise = seed_parsons_exercise
        exercise.problem_set["parsons_problem"].merge!(
          "blocks" => Array.new(count) { |i| "block #{i}" }, "display_order" => (0...count).to_a
        )
        exercise.save!
        user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
          answers: { "parsons_problem" => "order:#{(0...count).to_a.join(',')}" })
        stub_sortable_cdn(:loaded)
        visit_as(user)

        expect(page).to have_content("1 of 3 answered")
        expect(page).to have_button("Submit answers", disabled: true)
        rate_section("parsons_problem")
        expect(page).to have_button("Submit answers", disabled: false)
      end
    end
  end

  it "shows no arrow buttons once drag is available" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)

      expect(page).to have_css("ol[data-parsons-blocks][data-sortable-done]", wait: 10)
      expect(page).to have_no_css(".parsons-move-up")
      expect(page).to have_no_css(".parsons-move-down")
    end
  end

  it "injects working arrows when the CDN is unreachable" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :blocked)

      expect(page).to have_css(".parsons-move-up", count: 3, wait: 10)
      expect(page).to have_no_css("ol[data-parsons-blocks][data-sortable-done]")

      all(".parsons-move-down").first.click

      expect(block_ids).to eq([ "0", "2", "1" ])
      expect(hidden_answer).to eq("order:0,2,1")
    end
  end

  it "reorders with the keyboard, since dragging is pointer-only" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)
      expect(block_ids).to eq([ "2", "0", "1" ])
      rate_section("parsons_problem")
      expect(page).to have_button("Submit answers", disabled: true)

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(%i[control down])

      expect(block_ids).to eq([ "0", "2", "1" ])
      expect(page).to have_css(".parsons-status", text: "position 2 of 3", visible: :all)
      expect(hidden_answer).to eq("order:0,2,1")
      expect(page).to have_button("Submit answers", disabled: false)
    end
  end

  it "reloads when a save is refused because the problem changed under the page" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)
      exercise = user.daily_exercises.sole
      exercise.problem_set["parsons_problem"]["blocks"] = [ "def replaced(names)", "  names.uniq", "end" ]
      exercise.save!

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(%i[control down])

      expect(page).to have_css("ol[data-parsons-blocks] .parsons-block", text: "names.uniq", wait: 10)
      expect(user.daily_responses.reload).to be_empty
    end
  end

  # The reload wipes the banner, so without carrying the message the engineer's lost move goes unexplained.
  it "explains the refusal on the page the reload lands on" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)
      exercise = user.daily_exercises.sole
      exercise.problem_set["parsons_problem"]["blocks"] = [ "def replaced(names)", "  names.uniq", "end" ]
      exercise.save!

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(%i[control down])

      expect(page).to have_css("#save-status", text: "that last change wasn't saved", wait: 10)
    end
  end

  it "does not follow the reader to another page" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)
      page.execute_script("window.CodeGymSaveStatus.carry('answers', 'Reload to see the current problem.')")

      visit learn_path

      expect(page).to have_css("h1")
      expect(page).to have_no_css("#save-status", text: "Reload to see the current problem.")
    end
  end

  it "moves focus between blocks with a bare arrow key" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(:down)

      expect(block_ids).to eq([ "2", "0", "1" ])
      expect(block_positions[page.evaluate_script("document.activeElement.dataset.blockId")]).to eq(0)
    end
  end
end
