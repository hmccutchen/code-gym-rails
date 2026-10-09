require "rails_helper"

# A wrapped code line used to continue at column 0, and the padding that lines
# up a column (`kind     = value`) stayed as a wide gap once the block wrapped.
# These pin the hanging indent, which starts a continuation two columns past
# the line's own indentation, the alignment padding shown as one space in a
# block that wraps, and a copy that still holds the original lines.
RSpec.describe "Code block wrapping", type: :system do
  # Line 1 is too long for a phone but fits the desktop column. Line 2 opens a
  # string that crosses into line 3 and holds padding of its own after a comma.
  SOURCE = <<~RUBY.chomp.freeze
    def total
      kind     = "a string that is too long for a phone"
      label = "a,  b
      c"

      kind
    end
  RUBY
  HIGHLIGHT_JS = "**/*highlight*"

  let(:user) { create_fake_provider_user.tap { |u| u.update!(language: "ruby_rails") } }

  before do
    ConceptReference.create!(
      concept: "n_plus_one", language: "ruby_rails",
      tagline: "One query per row.", explanation: "Load what you need up front.",
      code_example: SOURCE, senior_lens: "Preload the association."
    )
  end

  # Highlighting happens on the server, so the page must not ask for a
  # browser highlighter at all. Every such request is counted and refused.
  def watch_for_highlighter(width:)
    @highlighter_requests = []
    page.driver.with_playwright_page do |pw|
      pw.set_viewport_size(width: width, height: 844)
      pw.route(HIGHLIGHT_JS, ->(route, request) {
        @highlighter_requests << request.url
        route.abort
      })
    end
  end

  # The Learn page folds its code examples closed, so every example here also
  # covers a block that was hidden at load and fitted when it opened.
  def open_reference(width: 390)
    watch_for_highlighter(width: width)
    visit_as(user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
    expect(page).to have_css("pre.snippet code.highlight[data-lines-done]", visible: :all, wait: 10)
    find("details.learn-code-examples summary").click
    expect(page).to have_css("pre.snippet code.highlight[data-lines-done]", wait: 5)
  end

  # Fitting runs from a ResizeObserver, a moment after the block opens or
  # resizes, so a check on its result retries until the gap matches.
  def expect_gap(index, columns, before: "=")
    page.document.synchronize(5) do
      actual = gap_columns(index, before: before)
      raise Capybara::ExpectationNotMet, "line #{index} showed #{actual} columns before `#{before}`, expected #{columns}" unless actual == columns
    end
  end

  # How many columns the line shows before the last `before` character in it,
  # back to the text ahead of the gap.
  def gap_columns(index, before: "=")
    page.evaluate_script(<<~JS)
      (() => {
        const line = document.querySelectorAll("pre.snippet .code-line")[#{index}];
        const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        const chars = [];
        while (walker.nextNode()) {
          for (let i = 0; i < walker.currentNode.length; i++) {
            const range = document.createRange();
            range.setStart(walker.currentNode, i);
            range.setEnd(walker.currentNode, i + 1);
            chars.push({ char: walker.currentNode.data[i], rect: range.getBoundingClientRect() });
          }
        }
        const target = chars.findLastIndex((c) => c.char === #{before.to_json});
        const name = chars.slice(0, target).findLastIndex((c) => c.char !== " ");
        const ch = chars[name].rect.width;
        return Math.round((chars[target].rect.left - chars[name].rect.right) / ch);
      })()
    JS
  end

  def copied_text
    page.evaluate_script(<<~JS)
      (() => {
        const range = document.createRange();
        range.selectNodeContents(document.querySelector("pre.snippet"));
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        return getSelection().toString();
      })()
    JS
  end

  def line_texts
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll("pre.snippet .code-line")].map((line) => line.textContent)
    JS
  end

  # Where the first and the wrapped fragments of one line start, against the
  # line's own left edge and its padding.
  def fragment_offsets(index)
    page.evaluate_script(<<~JS)
      (() => {
        const line = document.querySelectorAll("pre.snippet .code-line")[#{index}];
        const range = document.createRange();
        range.selectNodeContents(line);
        const rects = [...range.getClientRects()].filter((rect) => rect.width > 0);
        const box = line.getBoundingClientRect();
        return {
          fragments: rects.length,
          first: rects[0].left - box.left,
          continuation: rects.at(-1).left - box.left,
          padding: parseFloat(getComputedStyle(line).paddingLeft),
          ch: parseFloat(getComputedStyle(line).paddingLeft) / (Number(line.style.getPropertyValue("--indent")) + 2)
        };
      })()
    JS
  end

  context "on a phone" do
    before { open_reference }

    it "gives every source line its own block, blank lines included" do
      lines = all("pre.snippet .code-line", visible: :all)

      expect(lines.map { |line| line[:style][/--indent:\s*(\d+)/, 1] }).to eq(%w[0 2 2 2 0 2 0])
      expect(page.evaluate_script(<<~JS)).to be > 0
        document.querySelectorAll("pre.snippet .code-line")[4].getBoundingClientRect().height
      JS
    end

    it "starts a wrapped continuation two columns past the line's indentation" do
      offsets = fragment_offsets(1)

      expect(offsets["fragments"]).to be > 1
      expect(offsets["first"]).to be_within(1).of(0)
      expect(offsets["continuation"]).to be_within(1).of(offsets["padding"])
      expect(offsets["padding"]).to be_within(1).of(4 * offsets["ch"])
    end

    it "shows alignment padding as one space once the block wraps" do
      expect_gap(1, 1)
    end

    it "copies the original lines, padding and blank line included" do
      expect_gap(1, 1)

      expect(copied_text).to eq(SOURCE)
    end

    it "keeps the server's highlighting and asks for no browser highlighter" do
      expect(page).to have_css("pre.snippet code.highlight .code-line .nf", text: "total")
      expect(page).to have_no_css(".hljs, [data-hljs]")
      expect(@highlighter_requests).to be_empty
    end
  end

  it "keeps the padding inside a highlighted string" do
    open_reference
    expect_gap(1, 1)

    expect(gap_columns(2, before: "b")).to eq(2)
  end

  it "keeps every line as written where the block fits" do
    open_reference(width: 1280)

    expect(gap_columns(1)).to eq(5)
    expect(line_texts).to eq(SOURCE.lines.map(&:chomp).map { |line| line.empty? ? "\n" : line })
  end

  # The same observer fits a block that was in a closed disclosure at load,
  # since opening it changes its width from zero.
  it "fits the block again when its width changes" do
    open_reference(width: 1280)
    expect(gap_columns(1)).to eq(5)

    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    expect_gap(1, 1)

    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 1280, height: 844) }
    expect_gap(1, 5)
  end

  it "breaks a long call chain after a dot or parenthesis, never mid-name" do
    ConceptReference.last.update!(code_example: 'kind = ExerciseSection.for_key(section.fetch("kind")).with_rung(KindDifficulty.new.level)')
    open_reference

    # The character before each row break, found by walking the line one
    # character at a time and noting where its top edge moves down.
    before_breaks = page.evaluate_script(<<~JS)
      (() => {
        const line = document.querySelector("pre.snippet .code-line");
        const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        const chars = [];
        while (walker.nextNode()) {
          const node = walker.currentNode;
          for (let i = 0; i < node.length; i++) {
            const range = document.createRange();
            range.setStart(node, i);
            range.setEnd(node, i + 1);
            chars.push({ char: node.data[i], top: range.getBoundingClientRect().top });
          }
        }
        return chars.slice(1).filter((c, i) => c.top > chars[i].top + 1).map((c) => chars[chars.indexOf(c) - 1].char);
      })()
    JS

    expect(before_breaks).not_to be_empty
    expect(before_breaks).to all(match(/[.( ]/))
    expect(line_texts.first).to eq('kind = ExerciseSection.for_key(section.fetch("kind")).with_rung(KindDifficulty.new.level)')
  end

  it "marks a string that crosses lines as literal on every line it covers" do
    open_reference

    spans_per_line = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("pre.snippet .code-line")].map((line) => line.querySelectorAll(".code-literal").length)
    JS
    expect(spans_per_line).to eq([ 0, 1, 1, 1, 0, 0, 0 ])
  end

  it "wraps a hand-written lesson's code, which has no language and stays plain" do
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    visit_as(user)
    visit learn_lesson_path(lesson: "reading_unfamiliar_code")

    expect(page).to have_css("pre.snippet code.highlight[data-lines-done] .code-line", minimum: 2, wait: 10)
    expect(page).to have_no_css("pre.snippet code.highlight .code-line span:not(.code-align-extra)")
  end
end
