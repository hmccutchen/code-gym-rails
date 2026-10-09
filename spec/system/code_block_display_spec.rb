require "rails_helper"

# Code blocks on a phone with the display preferences applied: the page never
# scrolls sideways at the largest text size, and code takes its background
# and token colors from the theme.
RSpec.describe "Code blocks under display preferences", type: :system do
  # Lines as long as the longest in the judge fixtures, in the code example
  # and in the worked example, which renders as a paragraph.
  LONG_CODE = <<~RUBY.chomp.freeze
    class StatementExport
      def call
        @formatter.render(@statement.purchases.map { |purchase| [purchase.posted_on, purchase.merchant, purchase.amount.to_s("F")] })
      end
    end
  RUBY

  let(:user) { create_fake_provider_user.tap { |u| u.update!(language: "ruby_rails") } }

  before do
    ConceptReference.create!(
      concept: "n_plus_one", language: "ruby_rails",
      tagline: "One query per row.", explanation: "Load what you need up front.",
      code_example: LONG_CODE, senior_lens: "Preload the association.",
      guide_plain_language: "Ask once.", guide_worked_example: "Before:\n#{LONG_CODE}\nAfter: the same, preloaded.",
      guide_pitfalls: "Preloading what you never read."
    )
  end

  def open_learn_page(width:)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: 844) }
    visit_as(user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
    find("details.learn-code-examples summary").click
    expect(page).to have_css("pre.snippet code.highlight")
  end

  def page_scrolls_sideways?
    page.evaluate_script("document.documentElement.scrollWidth > window.innerWidth")
  end

  def code_background
    page.evaluate_script(%(getComputedStyle(document.querySelector("pre.snippet")).backgroundColor))
  end

  [ 320, 390 ].each do |width|
    it "keeps a page with long code from scrolling sideways at #{width}px and the largest text" do
      user.update!(display_preferences: { "text_size" => DisplayPreferences::OPTIONS["text_size"].last })
      open_learn_page(width: width)

      expect(page.evaluate_script("getComputedStyle(document.documentElement).fontSize")).to eq("22.4px")
      expect(page_scrolls_sideways?).to be(false)
    end
  end

  it "scales code with the text size setting" do
    open_learn_page(width: 390)
    default_size = page.evaluate_script(%(getComputedStyle(document.querySelector("pre.snippet code")).fontSize))

    user.update!(display_preferences: { "text_size" => "140" })
    visit current_path
    find("details.learn-code-examples summary").click

    expect(page.evaluate_script(%(getComputedStyle(document.querySelector("pre.snippet code")).fontSize)))
      .to eq("#{(default_size.to_f * 1.4).round(2)}px")
  end

  # No page puts code inside prose yet; the rule is there for the first one.
  it "keeps inline code at the size of the prose around it" do
    open_learn_page(width: 390)

    sizes = page.evaluate_script(<<~JS)
      (() => {
        const paragraph = document.createElement("p");
        paragraph.innerHTML = "Call <code>includes</code> first.";
        document.querySelector("main").append(paragraph);
        return [paragraph, paragraph.querySelector("code")].map((element) => getComputedStyle(element).fontSize);
      })()
    JS
    expect(sizes.uniq.size).to eq(1)
  end

  it "takes the code background from the dark theme by default and the light one when chosen" do
    open_learn_page(width: 390)
    expect(code_background).to eq("rgb(13, 13, 26)")

    user.update!(display_preferences: { "theme" => "light" })
    visit current_path
    expect(code_background).to eq("rgb(240, 240, 246)")
  end

  it "follows the device under Match my device" do
    user.update!(display_preferences: { "theme" => "device" })
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "light") }
    open_learn_page(width: 390)
    expect(code_background).to eq("rgb(240, 240, 246)")

    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    expect(code_background).to eq("rgb(13, 13, 26)")
  end
end
