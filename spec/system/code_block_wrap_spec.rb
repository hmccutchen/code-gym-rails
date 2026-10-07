require "rails_helper"

# A wrapped code line used to continue at column 0, and the padding that lines
# up a column (`kind     = value`) stayed as a wide gap once the block wrapped.
# These pin the hanging indent, which starts a continuation two columns past
# the line's own indentation, and the alignment padding shown as one space in
# a block that wraps.
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
  HLJS_URL = "**esm.sh/highlight.js**"

  let(:user) { create_fake_provider_user.tap { |u| u.update!(language: "ruby_rails") } }

  before do
    ConceptReference.create!(
      concept: "n_plus_one", language: "ruby_rails",
      tagline: "One query per row.", explanation: "Load what you need up front.",
      code_example: SOURCE, senior_lens: "Preload the association."
    )
  end

  # Highlighting loads from a CDN, so the spec decides that request's outcome
  # rather than leaving it to the runner's network. The stub's highlighter
  # marks each double-quoted string, across lines, as highlight.js does.
  def stub_highlighter(outcome, width:)
    page.driver.with_playwright_page do |pw|
      pw.set_viewport_size(width: width, height: 844)
      pw.route(HLJS_URL, ->(route, request) {
        next route.abort if outcome == :blocked

        body = if request.url.include?("/lib/core")
          <<~JS
            export default {
              registerLanguage() {},
              getLanguage() { return true; },
              highlight(text) {
                const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;");
                return { value: escaped.replace(/"[^"]*"/g, (string) => `<span class="hljs-string">${string}</span>`) };
              }
            };
          JS
        else
          "export default function () { return {}; };"
        end
        route.fulfill(status: 200, contentType: "application/javascript", body: body)
      })
    end
  end

  def open_reference(highlighter:, width: 390)
    stub_highlighter(highlighter, width: width)
    visit_as(user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
    expect(page).to have_css("pre.snippet code[data-lines-done]", wait: 10)
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

  [ :loaded, :blocked ].each do |highlighter|
    context "when highlighting has #{highlighter}" do
      before { open_reference(highlighter: highlighter) }

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
        expect(line_texts[1]).to eq('  kind = "a string that is too long for a phone"')
      end
    end
  end

  it "keeps the padding inside a highlighted string" do
    open_reference(highlighter: :loaded)

    expect(line_texts[2]).to eq('  label = "a,  b')
  end

  it "keeps every line as written where the block fits" do
    open_reference(highlighter: :loaded, width: 1280)

    expect(line_texts).to eq(SOURCE.lines.map(&:chomp))
  end

  # The same observer fits a block that was in a closed disclosure at load,
  # since opening it changes its width from zero.
  it "fits the block again when its width changes" do
    open_reference(highlighter: :loaded, width: 1280)
    expect(line_texts[1]).to start_with("  kind     =")

    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    expect(page).to have_css("pre.snippet .code-line", text: 'kind = "a string', wait: 5)

    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 1280, height: 844) }
    expect(page).to have_css("pre.snippet .code-line", text: "kind     =", wait: 5)
  end

  it "breaks a long call chain after a dot or parenthesis, never mid-name" do
    ConceptReference.last.update!(code_example: 'kind = ExerciseSection.for_key(section.fetch("kind")).with_rung(KindDifficulty.new.level)')
    open_reference(highlighter: :blocked)

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

  it "re-opens a highlight span that crosses lines on every line it covers" do
    open_reference(highlighter: :loaded)

    spans_per_line = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("pre.snippet .code-line")].map((line) => line.querySelectorAll(".hljs-string").length)
    JS
    expect(spans_per_line).to eq([ 0, 1, 1, 1, 0, 0, 0 ])
  end

  it "wraps a hand-written lesson's code, which is never highlighted" do
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    visit_as(user)
    visit learn_lesson_path(lesson: "reading_unfamiliar_code")

    expect(page).to have_css("pre.snippet code[data-lines-done] .code-line", minimum: 2, wait: 10)
  end
end
