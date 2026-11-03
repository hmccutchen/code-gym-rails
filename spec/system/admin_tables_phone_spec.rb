require "rails_helper"

RSpec.describe "Admin tables on a phone", type: :system do
  let(:admin) { create_fake_provider_user(email: "admin@example.com") }

  before do
    ENV["ADMIN_EMAILS"] = admin.email
    SuggestedConcept.record!(language: "ruby_rails", name: "a_suggested_concept_with_a_long_name")
    visit_as(admin)
  end

  after { ENV.delete("ADMIN_EMAILS") }

  def scroll_boxes
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".table-scroll")].map(box => {
        const label = document.getElementById(box.getAttribute("aria-labelledby"));
        return [box.tabIndex, box.getAttribute("role"), label ? label.textContent.trim() : ""];
      })
    JS
  end

  it "lets a keyboard reach each judge solves table box, named by its heading" do
    visit admin_judge_solves_path

    boxes = scroll_boxes
    expect(boxes.size).to eq(4)
    expect(boxes.map { |tab, role, _| [ tab, role ] }).to all(eq([ 0, "region" ]))
    expect(boxes.map(&:last)).to all(be_present)
    expect(boxes.map(&:last).uniq.size).to eq(4)
  end

  it "lets a keyboard reach the suggested concepts table box, named by the page heading" do
    visit admin_suggested_concepts_path

    expect(scroll_boxes).to eq([ [ 0, "region", I18n.t("admin.suggested_concepts.index.heading") ] ])
  end

  OVERFLOWING_BOXES = "[...document.querySelectorAll('.table-scroll')].filter(box => box.scrollWidth > box.clientWidth)".freeze

  # A wheel turn moves only a box the user can scroll, where setting scrollLeft from a script moves an overflow: hidden one too.
  def scroll_by_wheel(index)
    box = "#{OVERFLOWING_BOXES}[#{index}]"
    x, y = page.evaluate_script("(box => { box.scrollIntoView({ block: 'center' }); const r = box.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })(#{box})")
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(x, y)
      pw.mouse.wheel(200, 0)
    end
    wait_for { page.evaluate_script("#{box}.scrollLeft") > 0 }
  end

  [ [ :admin_judge_solves_path, "judge solves" ], [ :admin_suggested_concepts_path, "suggested concepts" ] ].each do |path, name|
    it "lets a user scroll each overflowing #{name} table sideways at 320px" do
      resize(320)
      visit public_send(path)

      count = page.evaluate_script("#{OVERFLOWING_BOXES}.length")
      expect(count).to be_positive
      count.times { |index| scroll_by_wheel(index) }
    end
  end

  [ 320, 390 ].each do |width|
    it "keeps the judge solves page within a #{width}px screen, scrolling each table in its own box" do
      resize(width)
      visit admin_judge_solves_path

      expect(page).to have_css(".table-scroll .solve-counts", count: 4)
      expect(sideways_overflow).to eq(0)
    end

    it "keeps the suggested concepts page within a #{width}px screen, scrolling the table in its own box" do
      resize(width)
      visit admin_suggested_concepts_path

      expect(page).to have_css(".table-scroll .suggested-table")
      expect(sideways_overflow).to eq(0)
      expect(find(".table-scroll").evaluate_script("this.scrollWidth > this.clientWidth")).to be(true)
    end
  end
end
