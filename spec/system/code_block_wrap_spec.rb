require "rails_helper"

# A wrapped code line used to continue at column 0, so an aligned
# `kind     = value` could put `value` on a line of its own. These pin the
# hanging indent: each source line is its own block, and its continuation
# starts two columns past the line's own indentation.
RSpec.describe "Code block wrapping", type: :system do
  LONG_VALUE = "\"#{'a very long string that cannot fit on a phone ' * 2}\"".freeze
  SOURCE = "def total\n  kind     = #{LONG_VALUE}\n\n  kind\nend".freeze
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
  # wraps the whole block in one span, the way highlight.js wraps a string or
  # comment that spans several lines.
  def stub_highlighter(outcome)
    page.driver.with_playwright_page do |pw|
      pw.set_viewport_size(width: 390, height: 844)
      pw.route(HLJS_URL, ->(route, request) {
        next route.abort if outcome == :blocked

        body = if request.url.include?("/lib/core")
          <<~JS
            export default {
              registerLanguage() {},
              getLanguage() { return true; },
              highlight(text) {
                const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;");
                return { value: `<span class="hljs-string">${escaped}</span>` };
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

  def open_reference(highlighter:)
    stub_highlighter(highlighter)
    visit_as(user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
    expect(page).to have_css("pre.snippet code[data-lines-done]", wait: 10)
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

        expect(lines.map { |line| line[:style][/--indent:\s*(\d+)/, 1] }).to eq(%w[0 2 0 2 0])
        expect(page.evaluate_script(<<~JS)).to be > 0
          document.querySelectorAll("pre.snippet .code-line")[2].getBoundingClientRect().height
        JS
      end

      it "starts a wrapped continuation two columns past the line's indentation" do
        offsets = fragment_offsets(1)

        expect(offsets["fragments"]).to be > 1
        expect(offsets["first"]).to be_within(1).of(0)
        expect(offsets["continuation"]).to be_within(1).of(offsets["padding"])
        expect(offsets["padding"]).to be_within(1).of(4 * offsets["ch"])
      end

      it "keeps the source text unchanged" do
        expect(page.evaluate_script(<<~JS)).to eq(SOURCE.lines.map(&:chomp))
          [...document.querySelectorAll("pre.snippet .code-line")].map((line) => line.textContent)
        JS
      end
    end
  end

  it "re-opens a highlight span that crosses lines on every line it covers" do
    open_reference(highlighter: :loaded)

    spans_per_line = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("pre.snippet .code-line")].map((line) => line.querySelectorAll(".hljs-string").length)
    JS
    expect(spans_per_line).to eq([ 1, 1, 0, 1, 1 ])
  end

  it "wraps a hand-written lesson's code, which is never highlighted" do
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    visit_as(user)
    visit learn_lesson_path(lesson: "reading_unfamiliar_code")

    expect(page).to have_css("pre.snippet code[data-lines-done] .code-line", minimum: 2, wait: 10)
  end
end
