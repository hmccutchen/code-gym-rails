require "rails_helper"

RSpec.describe "Learn layout", type: :system do
  def visit_learn(width:, height: 844, prefs: {}, featured: true)
    resize(width, height: height)
    user = create_fake_provider_user
    user.update!(language: "ruby_rails", display_preferences: prefs)
    if featured
      submit_set_showing(user, "n_plus_one", date: Date.current - 1)
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "T",
                               explanation: "E", code_example: "x", senior_lens: "S")
      ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
    end
    RecognitionGuide.create!(group_key: "code_smell", questions: "Q", contrast: "C", misfires: "M")
    visit_as(user)
    visit learn_path
    expect(page).to have_css(".learn-bucket-grouped h2")
  end

  def card_selector = ".featured-concept, .learn-filter, .learn-prepare, .learn-drills, .learn-group-block"

  def layout_facts
    [ ".featured-concept", ".learn-filter", ".learn-prepare", ".learn-drills", ".learn-group-block", ".learn-bucket" ].map { |selector| rects(selector) }
  end

  def grouped_cards = rects(".learn-bucket-grouped .learn-group-block")

  def flat_cards = rects(".learn-bucket:not(.learn-bucket-grouped) .learn-group-block")

  def content_width = container_content.then { |content| content["right"] - content["left"] }

  def expect_targets
    expect(rect("#learn-filter-input")["height"]).to be >= 48
    expect(rect(".learn-filter label")["height"]).to be >= 48
    expect(rects(".learn-page .btn-sm, .learn-entry a, .featured-title a").map { |r| r["height"] }).to all(be >= 44)
    expect(rects(".learn-entry, .learn-recognition > summary").map { |r| r["height"] }).to all(be >= 48)
  end

  def filter_for(term)
    find("#learn-filter-input").fill_in(with: term)
  end

  def shown(selector) = page.evaluate_script("[...document.querySelectorAll(#{selector.to_json})].filter(el => getComputedStyle(el).display !== 'none').length")

  describe "sideways scroll" do
    LayoutHelpers::LAYOUT_WIDTHS.each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "keeps Learn inside a #{width}px window#{' with the largest text' if prefs.any?}, with every disclosure open" do
          visit_learn(width: width, prefs: prefs)
          expect(sideways_overflow).to eq(0)
          open_every_disclosure
          expect(sideways_overflow).to eq(0)
        end
      end
    end

    it "keeps Learn inside 320px with the largest text and the spacing override" do
      visit_learn(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)
      open_every_disclosure
      apply_text_spacing
      expect(sideways_overflow).to eq(0)
    end
  end

  describe "the desktop stylesheet" do
    [ 390, 899 ].each do |width|
      it "changes nothing at #{width}px" do
        visit_learn(width: width)
        with_desktop = layout_facts
        without = without_desktop_rules { layout_facts }
        expect(without).to eq(with_desktop)
      end
    end

    it "takes effect at 900px" do
      visit_learn(width: 900)
      with_desktop = layout_facts
      without = without_desktop_rules { layout_facts }
      expect(without).not_to eq(with_desktop)
    end
  end

  describe "on a phone" do
    [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
      it "lays every box and group out as a 16px-inset card with 48px rows and 44px targets at #{width}px#{' with the largest text' if prefs.any?}" do
        visit_learn(width: width, prefs: prefs)

        edges(card_selector).each { |pair| expect(pair).to all(be_within(0.5).of(16)) }
        expect(computed_style(".learn-group-block", "borderTopLeftRadius")).to eq("14px")
        grouped_cards.each_cons(2) { |above, below| expect(below["top"] - above["bottom"]).to be_within(0.5).of(16) }
        expect(rect(".learn-filter")["top"] - rect(".featured-concept")["bottom"]).to be_within(0.5).of(16)
        expect_targets
      end
    end

    it "keeps cards clear of a 44px notch" do
      set_safe_area(left: 44, right: 44)
      visit_learn(width: 390)
      edges(card_selector).each { |pair| expect(pair).to all(be_within(0.5).of(44)) }
      expect(sideways_overflow).to eq(0)
    end

    it "spans the container in landscape with a notch, under 900px" do
      set_safe_area(left: 47, right: 47)
      visit_learn(width: 844, height: 390)
      content = container_content
      rects(card_selector).each do |card|
        expect(card["left"]).to be_within(0.5).of(content["left"])
        expect(card["right"]).to be_within(0.5).of(content["right"])
      end
      expect(content["left"] - rect(".container[data-pull-content]")["left"]).to be_within(0.5).of(47)
      expect(sideways_overflow).to eq(0)
    end
  end

  it "takes the container's full width between 600 and 899px, with the filter below this week's concept" do
    visit_learn(width: 768)
    content = container_content
    rects(card_selector).each do |card|
      expect(card["left"]).to be_within(0.5).of(content["left"])
      expect(card["right"]).to be_within(0.5).of(content["right"])
    end
    expect(rect(".learn-filter")["top"]).to be > rect(".featured-concept")["bottom"]
  end

  describe "the filter" do
    [ 390, 1280 ].each do |width|
      it "hides the entries, groups and buckets it doesn't match at #{width}px" do
        visit_learn(width: width)

        filter_for("n plus one")
        expect(page).to have_css(".learn-entry", visible: :visible, count: 1)
        expect(shown(".learn-group-block")).to eq(1)
        expect(shown(".learn-bucket")).to eq(1)

        filter_for("no such concept anywhere")
        expect(page).to have_css("#learn-empty", visible: :visible)
        expect(shown(".learn-bucket")).to eq(0)
      end
    end
  end

  describe "on a desktop" do
    [ 900, 1280, 1920 ].each do |width|
      it "centers min(1040, window minus gutters) of content at #{width}px" do
        visit_learn(width: width)
        content = container_content
        expect(content["right"] - content["left"]).to be_within(0.5).of([ 1040, width - 48 ].min)
        expect(content["left"]).to be_within(1).of(client_width - content["right"])
      end
    end

    it "puts this week's concept beside the filter, and groups and single-group buckets three across" do
      visit_learn(width: 1280)
      half = (content_width - 16) / 2.0
      third = (content_width - 32) / 3.0

      featured = rect(".featured-concept")
      filter = rect(".learn-filter")
      expect(filter["top"]).to be_within(0.5).of(featured["top"])
      [ featured, filter ].each { |card| expect(card["width"]).to be_within(0.5).of(half) }

      expect(flat_cards.size).to eq(ConceptBucket::LANGUAGE_INDEPENDENT.size), "this example expects one card per language-independent bucket"
      expect(flat_cards.size).to be >= 4, "this example needs a fourth single-group card to start a second row"
      [ grouped_cards, flat_cards ].each do |cards|
        expect(cards[1..2].map { |r| r["top"] }).to all(be_within(0.5).of(cards[0]["top"]))
        expect(cards[3]["top"]).to be >= cards[0]["bottom"]
        cards.first(4).each { |card| expect(card["width"]).to be_within(0.5).of(third) }
      end
    end

    it "leaves the cards beside an open guide at their own height" do
      visit_learn(width: 1280)
      guide_card = page.evaluate_script("[...document.querySelectorAll('.learn-bucket-grouped .learn-group-block')].findIndex(el => el.querySelector('.learn-recognition'))")
      row_start = guide_card - (guide_card % 3)
      neighbours = (row_start...row_start + 3).to_a - [ guide_card ]
      before = neighbours.map { |i| grouped_cards[i]["height"] }

      find(".learn-recognition > summary").click
      expect(page).to have_css(".learn-recognition[open]")

      expect(neighbours.map { |i| grouped_cards[i]["height"] }).to eq(before)
    end

    it "holds every summary, row and target to its size" do
      visit_learn(width: 1280)
      expect_targets
    end

    it "spans the filter across the top row when there's no concept this week" do
      visit_learn(width: 1280, featured: false)
      expect(rect(".learn-filter")["width"]).to be_within(0.5).of(content_width)
    end

    it "lays the desktop grids inside a Pro Max's landscape insets" do
      set_safe_area(left: 59, right: 59)
      visit_learn(width: 932, height: 430)
      cards = grouped_cards
      expect(cards[1]["top"]).to be_within(0.5).of(cards[0]["top"])
      expect(cards[0]["left"]).to be_within(0.5).of(59)
      expect(client_width - cards[2]["right"]).to be_within(0.5).of(59)
      expect(sideways_overflow).to eq(0)
    end
  end
end
