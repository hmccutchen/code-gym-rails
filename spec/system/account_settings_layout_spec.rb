require "rails_helper"

RSpec.describe "Account and Settings layout", type: :system do
  def visit_page(path, width:, height: 844, prefs: {}, push: false)
    resize(width, height: height)
    run = -> {
      user = create_fake_provider_user
      user.update!(display_preferences: prefs)
      visit_as(user)
      visit path
      expect(page).to have_css(".phone-page h1")
    }
    push ? with_push_credentials(&run) : without_push_credentials(&run)
  end

  def open_settings = page.execute_script("document.querySelectorAll('details.card').forEach(details => details.open = true)")

  def account_cards = rects(".account-page > .card")

  def settings_cards = rects(".settings-page > .card")

  def content_width = container_content.then { |content| content["right"] - content["left"] }

  def kind_rows(group_index)
    page.evaluate_script(<<~JS)
      (() => {
        const group = document.querySelectorAll("#exercise-mix fieldset.mix-group")[#{group_index}];
        const kinds = group.querySelector(".mix-kinds").getBoundingClientRect();
        return { width: kinds.width, rows: [...group.querySelectorAll(".mix-kinds > .mix-row")].map(row => {
          const r = row.getBoundingClientRect();
          return { left: r.left, top: r.top, bottom: r.bottom, width: r.width, height: r.height };
        }) };
      })()
    JS
  end

  def group_count = page.evaluate_script("document.querySelectorAll('#exercise-mix fieldset.mix-group').length")

  def layout_facts = [ rects(".phone-page > .card"), rects(".mix-row") ]

  describe "sideways scroll" do
    LayoutHelpers::LAYOUT_WIDTHS.each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "keeps Account and Settings inside a #{width}px window#{' with the largest text' if prefs.any?}" do
          visit_page(account_path, width: width, prefs: prefs, push: true)
          expect(sideways_overflow).to eq(0)
          visit setup_path
          open_settings
          expect(sideways_overflow).to eq(0)
        end
      end
    end

    it "keeps both pages inside 320px with the largest text and the spacing override" do
      visit_page(account_path, width: 320, prefs: LayoutHelpers::LARGEST_TEXT, push: true)
      apply_text_spacing
      expect(sideways_overflow).to eq(0)
      visit setup_path
      open_settings
      apply_text_spacing
      expect(sideways_overflow).to eq(0)
    end
  end

  describe "the desktop rules" do
    [ 390, 768, 899 ].each do |width|
      it "change nothing at #{width}px" do
        visit_page(account_path, width: width, push: true)
        expect(without_desktop_rules { layout_facts }).to eq(layout_facts)
        visit setup_path
        open_settings
        expect(without_desktop_rules { layout_facts }).to eq(layout_facts)
      end
    end

    it "take effect at 900px" do
      visit_page(setup_path, width: 900)
      open_settings
      expect(without_desktop_rules { layout_facts }).not_to eq(layout_facts)
    end
  end

  it "keeps both pages a centered 480px column between 600 and 899px" do
    visit_page(account_path, width: 768, push: true)
    content = container_content
    cards = account_cards
    visit setup_path
    (cards + settings_cards).each do |card|
      expect(card["width"]).to be_within(0.5).of(480)
      expect(card["left"] - content["left"]).to be_within(1).of(content["right"] - card["right"])
    end
  end

  describe "Account on a desktop" do
    [ 900, 1280, 1920 ].each do |width|
      it "spans the title and the identity card, then pairs the cards with push at #{width}px" do
        visit_page(account_path, width: width, push: true)
        full = [ 1040, width - 48 ].min
        expect(content_width).to be_within(0.5).of(full)

        identity, *rest = account_cards
        expect(identity["width"]).to be_within(0.5).of(full)
        expect(rect(".account-page > h1")["width"]).to be_within(0.5).of(full)
        expect(rest.size).to eq(6)
        rest.each_slice(2) do |left, right|
          expect(right["top"]).to be_within(0.5).of(left["top"])
          expect(right["height"]).to be_within(0.5).of(left["height"])
          expect(right["left"] - left["right"]).to be_within(0.5).of(16)
          expect(left["width"]).to be_within(0.5).of((full - 16) / 2.0)
        end
      end
    end

    it "lets the Danger zone sit alone at half width when there's no Reminders card" do
      visit_page(account_path, width: 1280)
      _identity, *rest = account_cards
      expect(rest.size).to eq(5)
      rest.first(4).each_slice(2) { |left, right| expect(right["top"]).to be_within(0.5).of(left["top"]) }
      danger = rest.last
      expect(danger["top"]).to be > rest[2]["bottom"]
      expect(danger["width"]).to be_within(0.5).of((1040 - 16) / 2.0)
    end
  end

  describe "Settings on a desktop" do
    it "puts Connection beside Your day and spans the two disclosures" do
      visit_page(setup_path, width: 1280)
      open_settings
      connection, your_day, mix, display = settings_cards
      expect(your_day["top"]).to be_within(0.5).of(connection["top"])
      [ connection, your_day ].each { |card| expect(card["width"]).to be_within(0.5).of((1040 - 16) / 2.0) }
      [ mix, display ].each { |card| expect(card["width"]).to be_within(0.5).of(1040) }
    end

    it "lays each Exercise mix group's kinds two across" do
      visit_page(setup_path, width: 1280)
      open_settings
      (0...group_count).each do |index|
        group = kind_rows(index)
        half = (group["width"] - 16) / 2.0
        rows = group["rows"]
        rows.each { |row| expect(row["width"]).to be_within(0.5).of(half) }
        next if rows.size < 2

        expect(rows[1]["top"]).to be_within(0.5).of(rows[0]["top"])
        expect(rows[1]["left"] - (rows[0]["left"] + rows[0]["width"])).to be_within(0.5).of(16)
        expect(rows[2]["top"]).to be >= rows[0]["bottom"] if rows.size > 2
      end
    end

    it "leaves the kind beside an open About at its own height" do
      visit_page(setup_path, width: 1280)
      page.execute_script("document.querySelector('#exercise-mix').open = true")
      before = kind_rows(0)["rows"][1]["height"]
      page.execute_script("document.querySelector('#exercise-mix fieldset.mix-group .mix-row details.kind-about').open = true")
      expect(kind_rows(0)["rows"][0]["height"]).to be > kind_rows(0)["rows"][1]["height"]
      expect(kind_rows(0)["rows"][1]["height"]).to be_within(0.5).of(before)
    end

    it "keeps every target its phone size" do
      visit_page(setup_path, width: 1280)
      open_settings
      expect(rects(".settings-page .btn-block, .settings-page .switch-row, .settings-page details.card > summary, .settings-page .mix-level").map { |r| r["height"] }).to all(be >= 48)
      expect(rects(".settings-page .segment").map { |r| r["height"] }).to all(be >= 44)
      expect(rects(".settings-page .value-row").map { |r| r["height"] }).to all(be >= 52)
    end
  end

  it "lays both desktop grids inside a Pro Max's landscape insets" do
    set_safe_area(left: 59, right: 59)
    visit_page(account_path, width: 932, height: 430, push: true)
    _identity, first, second = account_cards
    expect(second["top"]).to be_within(0.5).of(first["top"])
    expect(first["left"]).to be_within(0.5).of(59)
    expect(client_width - second["right"]).to be_within(0.5).of(59)
    expect(sideways_overflow).to eq(0)
    visit setup_path
    connection, your_day = settings_cards
    expect(your_day["top"]).to be_within(0.5).of(connection["top"])
    expect(sideways_overflow).to eq(0)
  end
end
