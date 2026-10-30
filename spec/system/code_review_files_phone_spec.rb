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
    { "file_1_path" => "app/models/order.rb", "file_1_code" => ORDER_CODE, "file_1_changed_lines" => [ 2 ],
      "file_2_path" => "app/models/line_item.rb", "file_2_code" => "def price\n  0\nend", "file_2_changed_lines" => [] }
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

  def gutter_numbers
    page.evaluate_script(<<~JS)
      (() => {
        const code = document.querySelectorAll("details.comparison-piece")[1].querySelector("code")
        const blockLeft = code.parentElement.getBoundingClientRect().left
        const lines = [...code.querySelectorAll(".code-line")].map((line) => {
          const number = getComputedStyle(line, "::before")
          const numberLeft = line.getBoundingClientRect().left + parseFloat(number.left)
          return {
            counted: number.content.includes("counter(code-line)") && getComputedStyle(line).counterIncrement === "code-line 1",
            left_of_code: parseFloat(number.left) < 0,
            inside_block: numberLeft >= blockLeft
          }
        })
        return { restarts: getComputedStyle(code).counterReset === "code-line 0", lines }
      })()
    JS
  end

  def copied_text
    page.evaluate_script(<<~JS)
      (() => {
        const range = document.createRange()
        range.selectNodeContents(document.querySelectorAll("details.comparison-piece")[1].querySelector("code"))
        getSelection().removeAllRanges()
        getSelection().addRange(range)
        return getSelection().toString()
      })()
    JS
  end

  it "numbers every line in a gutter left of the code, and copies the code without the numbers" do
    travel_to(a_weekday) do
      open_dashboard(create_fake_provider_user)

      numbered_line = { "counted" => true, "left_of_code" => true, "inside_block" => true }
      expect(gutter_numbers).to eq("restarts" => true, "lines" => Array.new(3, numbered_line))
      expect(copied_text).to eq("def price\n  0\nend")
      expect(sideways_overflow).to eq(0)
    end
  end

  it "wraps a long path with no spaces instead of scrolling sideways" do
    long_path = "app/services/#{"subscription_renewal" * 5}.rb"
    files["file_2_path"] = long_path

    travel_to(a_weekday) do
      open_dashboard(create_fake_provider_user)

      expect(page).to have_css("details.comparison-piece summary", text: long_path)
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
