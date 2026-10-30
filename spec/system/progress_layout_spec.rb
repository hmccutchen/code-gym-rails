require "rails_helper"

RSpec.describe "Progress layout", type: :system do
  def visit_progress(width:, height: 844, prefs: {})
    resize(width, height: height)
    user = create_fake_provider_user
    user.update!(language: "ruby_rails", display_preferences: prefs)
    submit_set_showing(user, "n_plus_one", date: Date.current - 2, ai: "solid")
    submit_set_showing(user, "god_object", date: Date.current - 1)
    visit_as(user)
    visit progress_path
    expect(page).to have_css(".progress-bucket-grouped h2")
  end

  def card_selector = ".progress-legend-card, details.progress-group"

  def layout_facts
    [ rects(".progress-legend-card"), rects(".progress-legend > div"), rects("details.progress-group"), rects(".progress-bucket") ]
  end

  def open_legend = page.execute_script("document.querySelector('.progress-legend-card').open = true")

  def grouped_cards = rects(".progress-bucket-grouped details.progress-group")

  def flat_cards = rects(".progress-bucket:not(.progress-bucket-grouped) details.progress-group")

  def expect_targets
    expect(rects(".progress-legend-card > summary, details.progress-group > summary").map { |r| r["height"] }).to all(be >= 48)
    open_every_disclosure
    expect(rects(".progress-entry").map { |r| r["height"] }).to all(be >= 48)
    expect(rects(".progress-entry a").map { |r| r["height"] }).to all(be >= 44)
  end

  describe "sideways scroll" do
    LayoutHelpers::LAYOUT_WIDTHS.each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "keeps Progress inside a #{width}px window#{' with the largest text' if prefs.any?}, with every disclosure open" do
          visit_progress(width: width, prefs: prefs)
          expect(sideways_overflow).to eq(0)
          open_every_disclosure
          expect(sideways_overflow).to eq(0)
        end
      end
    end

    it "keeps Progress inside 320px with the largest text and the spacing override" do
      visit_progress(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)
      open_every_disclosure
      apply_text_spacing
      expect(sideways_overflow).to eq(0)
    end
  end

  describe "the desktop stylesheet" do
    [ 390, 899 ].each do |width|
      it "changes nothing at #{width}px" do
        visit_progress(width: width)
        open_every_disclosure
        with_desktop = layout_facts
        without = without_desktop_rules { layout_facts }
        expect(without).to eq(with_desktop)
      end
    end

    it "takes effect at 900px" do
      visit_progress(width: 900)
      open_every_disclosure
      with_desktop = layout_facts
      without = without_desktop_rules { layout_facts }
      expect(without).not_to eq(with_desktop)
    end
  end

  describe "on a phone" do
    [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
      it "lays the legend and groups out as full-width cards with 48px rows and 44px links at #{width}px#{' with the largest text' if prefs.any?}" do
        visit_progress(width: width, prefs: prefs)

        expect(page).to have_css(".progress-legend-card:not([open])")
        expect(page).to have_css(".progress-note", visible: :visible)
        edges(card_selector).each { |pair| expect(pair).to all(be_within(0.5).of(0)) }
        expect(computed_style("details.progress-group", "borderTopLeftRadius")).to eq("0px")
        expect(computed_style(".progress-legend-card", "borderTopLeftRadius")).to eq("0px")
        grouped_cards.each_cons(2) { |above, below| expect(below["top"] - above["bottom"]).to be_within(0.5).of(16) }
        expect_targets
        expect(rects(".progress-legend dt").map { |r| r["left"] }.uniq.size).to eq(1)
      end
    end

    it "keeps cards clear of a 44px notch" do
      set_safe_area(left: 44, right: 44)
      visit_progress(width: 390)
      edges(card_selector).each { |pair| expect(pair).to all(be_within(0.5).of(44)) }
      expect(sideways_overflow).to eq(0)
    end

    it "spans the container in landscape with a notch, under 900px" do
      set_safe_area(left: 47, right: 47)
      visit_progress(width: 844, height: 390)
      content = container_content
      rects(card_selector).each do |card|
        expect(card["left"]).to be_within(0.5).of(content["left"])
        expect(card["right"]).to be_within(0.5).of(content["right"])
      end
      expect(content["left"] - rect(".container[data-pull-content]")["left"]).to be_within(0.5).of(47)
      expect(sideways_overflow).to eq(0)
    end
  end

  it "takes the container's full width between 600 and 899px, with the legend two across" do
    visit_progress(width: 768)
    open_legend
    content = container_content
    rects(card_selector).each do |card|
      expect(card["left"]).to be_within(0.5).of(content["left"])
      expect(card["right"]).to be_within(0.5).of(content["right"])
    end
    first, second, third = rects(".progress-legend > div")
    expect(second["top"]).to be_within(0.5).of(first["top"])
    expect(third["top"]).to be >= first["bottom"]
  end

  describe "on a desktop" do
    [ 900, 1280, 1920 ].each do |width|
      it "centers min(1040, window minus gutters) of content at #{width}px" do
        visit_progress(width: width)
        content = container_content
        expect(content["right"] - content["left"]).to be_within(0.5).of([ 1040, width - 48 ].min)
        expect(content["left"]).to be_within(1).of(client_width - content["right"])
      end
    end

    it "lays the open legend four across, and groups and single-group buckets two across" do
      visit_progress(width: 1280)
      open_legend
      legend = rects(".progress-legend > div")
      expect(legend[1..3].map { |r| r["top"] }).to all(be_within(0.5).of(legend[0]["top"]))
      expect(legend[4]["top"]).to be >= legend[0]["bottom"]

      first, second = grouped_cards
      expect(second["top"]).to be_within(0.5).of(first["top"])
      expect(second["left"] - first["right"]).to be_within(0.5).of(16)

      flat_first, flat_second = flat_cards
      expect(flat_second["top"]).to be_within(0.5).of(flat_first["top"])
      expect(flat_second["left"] - flat_first["right"]).to be_within(0.5).of(16)
      [ first, second, flat_first, flat_second ].each { |card| expect(card["width"]).to be_within(0.5).of((1040 - 16) / 2.0) }
    end

    it "leaves the group beside an open one at its own height" do
      visit_progress(width: 1280)
      before = grouped_cards[1]["height"]
      page.execute_script("document.querySelector('.progress-bucket-grouped details.progress-group').open = true")
      expect(grouped_cards[0]["height"]).to be > before
      expect(grouped_cards[1]["height"]).to be_within(0.5).of(before)
    end

    it "holds the note to a reading width, and the summaries, rows and concept links to their target sizes" do
      visit_progress(width: 1280)
      note_width, max_width = page.evaluate_script(<<~JS)
        (() => { const el = document.querySelector(".progress-note"); return [el.getBoundingClientRect().width, parseFloat(getComputedStyle(el).maxWidth)]; })()
      JS
      content = container_content
      expect(note_width).to be <= max_width + 0.5
      expect(max_width).to be < content["right"] - content["left"]
      expect_targets
    end

    it "lays the desktop grid inside a Pro Max's landscape insets" do
      set_safe_area(left: 59, right: 59)
      visit_progress(width: 932, height: 430)
      first, second = grouped_cards
      expect(second["top"]).to be_within(0.5).of(first["top"])
      expect(first["left"]).to be_within(0.5).of(59)
      expect(client_width - second["right"]).to be_within(0.5).of(59)
      expect(sideways_overflow).to eq(0)
    end
  end
end
