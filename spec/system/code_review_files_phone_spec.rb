require "rails_helper"

RSpec.describe "A multi-file code review on a phone", type: :system do
  # Line 2 holds alignment padding and is too long for 320px, so the code-lines controller has a wrap to fit.
  ORDER_CODE = <<~RUBY.chomp.freeze
    def total
      kind     = "a string that is too long for a phone screen"
      kind
    end
  RUBY

  let(:files) do
    { "file_1_path" => "app/models/order.rb", "file_1_code" => ORDER_CODE, "file_1_changed" => [ 2 ],
      "file_2_path" => "app/models/line_item.rb", "file_2_code" => "def price\n  0\nend", "file_2_changed" => [] }
  end

  def open_dashboard(user)
    resize(320)
    visit_with_todays_set(user)
    exercise = DailyExercise.find_by!(user: user, date: Date.current)
    code_review = exercise.problem_set["code_review"].except("snippet", "diagram").merge(files)
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => code_review))
    visit root_path
    wait_for_js
  end

  def first_file = find("details.comparison-piece", match: :first)

  def align_extra_font_size
    page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("details.comparison-piece .code-align-extra")).fontSize
    JS
  end

  it "shows each file open under its path, marks the changed line and keeps the page from scrolling sideways" do
    travel_to(a_weekday) do
      open_dashboard(create_fake_provider_user)

      expect(page).to have_css("details.comparison-piece[open] summary", text: "app/models/order.rb — changed line 2")
      expect(page).to have_css("details.comparison-piece[open] summary", text: "app/models/line_item.rb")
      expect(first_file).to have_css(".code-line.code-line-changed", text: "kind", count: 1)
      expect(sideways_overflow).to eq(0)
    end
  end

  it "hides a wrapped line's alignment padding again after the file is folded and reopened" do
    travel_to(a_weekday) do
      open_dashboard(create_fake_provider_user)
      expect(first_file).to have_css("code.highlight[data-wraps]")

      first_file.find("summary").click
      expect(page).to have_css("details.comparison-piece:not([open])", count: 1)
      first_file.find("summary").click

      expect(first_file).to have_css("code.highlight[data-wraps]")
      expect(align_extra_font_size).to eq("0px")
      expect(sideways_overflow).to eq(0)
    end
  end
end
