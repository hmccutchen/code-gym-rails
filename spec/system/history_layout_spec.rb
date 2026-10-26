require "rails_helper"

RSpec.describe "History layout", type: :system do
  def long_path = "app/controllers/push_subscriptions_controller_with_a_longer_name.rb"

  def submitted_days(user, count: DailyResponse::HISTORY_PAGE_SIZE + 1)
    count.times do |i|
      date = Date.current - (i + 1)
      exercise = DailyExercise.create!(
        user: user, date: date, generated_at: Time.current,
        problem_set: {
          "code_review" => { "question" => "Why does #{long_path} fail?", "scenario" => "Open #{long_path}.", "snippet" => "def a; end" },
          "pattern" => { "title" => "Pattern", "question" => "When would #{long_path} use it?" }
        }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
        answers: { "code_review" => "See #{long_path} here.", "pattern" => "See #{long_path} here." },
        section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
        ai_review: { "code_review" => { "rating" => "solid", "correct" => "Check #{long_path} first. #{'A sentence long enough to wrap. ' * 12}" },
                     "pattern" => { "rating" => "solid", "correct" => "Good." } }
      )
    end
  end

  def visit_history(width:, height: 844, prefs: {})
    resize(width, height: height)
    user = create_fake_provider_user
    user.update!(display_preferences: prefs)
    submitted_days(user)
    visit_as(user)
    visit history_path
    expect(page).to have_css(".history-entry .review-block")
  end

  def entry_edges
    rects(".history-entry").map { |r| [ r["left"], page.evaluate_script("document.documentElement.clientWidth") - r["right"] ] }
  end

  def computed(selector, property)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).#{property}")
  end

  def container_content
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("#main-content").closest(".container");
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return { left: r.left + parseFloat(s.paddingLeft), right: r.right - parseFloat(s.paddingRight) };
      })()
    JS
  end

  def layout_facts
    [ rect(".history-rail"), rects(".history-entry"), rect("nav.pagination") ]
  end

  def without_desktop_stylesheet
    page.execute_script("document.querySelector('link[href*=\"/desktop\"]').sheet.disabled = true")
    yield
  ensure
    page.execute_script("document.querySelector('link[href*=\"/desktop\"]').sheet.disabled = false")
  end

  describe "sideways scroll" do
    LayoutHelpers::LAYOUT_WIDTHS.each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "keeps History inside a #{width}px window#{' with the largest text' if prefs.any?}, with every disclosure open" do
          travel_to(a_weekday) do
            visit_history(width: width, prefs: prefs)
            expect(sideways_overflow).to eq(0)
            open_every_disclosure
            expect(sideways_overflow).to eq(0)
          end
        end
      end
    end

    it "keeps History inside 320px with the largest text and the spacing override" do
      travel_to(a_weekday) do
        visit_history(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)
        apply_text_spacing
        open_every_disclosure
        expect(sideways_overflow).to eq(0)
      end
    end

    [ 1280, 1920 ].each do |width|
      it "leaves a page that isn't wide inside a #{width}px window" do
        travel_to(a_weekday) do
          resize(width)
          visit_with_todays_set(create_fake_provider_user)
          expect(sideways_overflow).to eq(0)
        end
      end
    end
  end

  describe "the desktop stylesheet" do
    [ 390, 899 ].each do |width|
      it "changes nothing at #{width}px" do
        travel_to(a_weekday) do
          visit_history(width: width)
          with_desktop = layout_facts
          without = without_desktop_stylesheet { layout_facts }
          expect(without).to eq(with_desktop)
        end
      end
    end

    it "takes effect at 900px" do
      travel_to(a_weekday) do
        visit_history(width: 900)
        with_desktop = layout_facts
        without = without_desktop_stylesheet { layout_facts }
        expect(without).not_to eq(with_desktop)
      end
    end
  end

  describe "on a phone" do
    [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
      it "lays entries out as 16px-inset cards with 48px disclosures and 44px pager buttons at #{width}px#{' with the largest text' if prefs.any?}" do
        travel_to(a_weekday) do
          visit_history(width: width, prefs: prefs)

          entry_edges.each { |edges| expect(edges).to all(be_within(0.5).of(16)) }
          expect(computed(".history-entry", "paddingLeft")).to eq("16px")
          expect(computed(".history-entry", "borderTopLeftRadius")).to eq("14px")
          entries = rects(".history-entry")
          entries.each_cons(2) { |above, below| expect(below["top"] - above["bottom"]).to be_within(0.5).of(16) }
          expect(rects("details.answers > summary, details.review > summary").map { |r| r["height"] }).to all(be >= 48)
          expect(rects(".pagination a").map { |r| r["height"] }).to all(be >= 44)
          expect(computed(".history-rail-page", "display")).to eq("none")
        end
      end
    end

    it "keeps entries clear of a 44px notch" do
      travel_to(a_weekday) do
        set_safe_area(left: 44, right: 44)
        visit_history(width: 390)
        entry_edges.each { |edges| expect(edges).to all(be_within(0.5).of(44)) }
        expect(sideways_overflow).to eq(0)
      end
    end

    it "puts entries at a 20px inset, not at 16px" do
      travel_to(a_weekday) do
        set_safe_area(left: 20)
        visit_history(width: 390)
        entry_edges.each do |left, right|
          expect(left).to be_within(0.5).of(20)
          expect(right).to be_within(0.5).of(16)
        end
      end
    end

    it "spans the container in landscape with a notch, under 900px" do
      travel_to(a_weekday) do
        set_safe_area(left: 47, right: 47)
        visit_history(width: 844, height: 390)
        content = container_content
        expect(content["left"] - rect(".container[data-pull-content]")["left"]).to be_within(0.5).of(47)
        rects(".history-entry").each do |entry|
          expect(entry["left"]).to be_within(0.5).of(content["left"])
          expect(entry["right"]).to be_within(0.5).of(content["right"])
        end
        expect(rect(".history-rail")["bottom"]).to be <= rects(".history-entry").first["top"]
        expect(sideways_overflow).to eq(0)
      end
    end
  end

  it "takes the container's full width between 600 and 899px, with the rail above the entries" do
    travel_to(a_weekday) do
      visit_history(width: 768)
      content = container_content
      rects(".history-entry").each do |entry|
        expect(entry["left"]).to be_within(0.5).of(content["left"])
        expect(entry["right"]).to be_within(0.5).of(content["right"])
      end
      expect(content["left"]).to be_within(0.5).of(24)
      expect(rect(".history-rail")["bottom"]).to be <= rects(".history-entry").first["top"]
    end
  end

  describe "on a desktop" do
    it "puts a 240px rail beside the entries at 900px" do
      travel_to(a_weekday) do
        visit_history(width: 900)
        content = container_content
        rail = rect(".history-rail")
        entries = rect(".history-entries")

        expect(content["right"] - content["left"]).to be_within(0.5).of(900 - 48)
        expect(rail["width"]).to be_within(0.5).of(240)
        expect(entries["left"] - rail["right"]).to be_within(0.5).of(24)
        expect(entries["top"]).to be_within(0.5).of(rail["top"])
        expect(computed(".history-rail-page", "display")).to eq("block")
        expect(computed(".history-entry", "paddingLeft")).to eq("20px")
      end
    end

    [ 1280, 1920 ].each do |width|
      it "centers 1040px of content at #{width}px" do
        travel_to(a_weekday) do
          visit_history(width: width)
          content = container_content
          expect(content["right"] - content["left"]).to be_within(0.5).of(1040)
          expect(content["left"]).to be_within(1).of(page.evaluate_script("document.documentElement.clientWidth") - content["right"])
        end
      end
    end

    [ 1280, 1920 ].each do |width|
      it "lines the nav's brand up with the page content's left edge at #{width}px" do
        travel_to(a_weekday) do
          visit_history(width: width)
          expect(rect("nav .brand")["left"]).to be_within(1).of(container_content["left"])
        end
      end
    end

    it "ends the nav's links at the content's right edge, and keeps the nav in place on a page that isn't wide" do
      travel_to(a_weekday) do
        visit_history(width: 1280)
        expect(rect("nav .nav-links")["right"]).to be_within(1).of(container_content["right"])
        brand_on_history = rect("nav .brand")["left"]

        visit learn_path
        expect(page).to have_css(".container[data-pull-content]:not(.container-wide)")
        expect(rect("nav .brand")["left"]).to be_within(0.5).of(brand_on_history)
      end
    end

    it "holds the open review to a reading width, and every target to 44px" do
      travel_to(a_weekday) do
        visit_history(width: 1280)
        review = page.evaluate_script(<<~JS)
          (() => {
            const el = document.querySelector("details.review[open]");
            return [el.getBoundingClientRect().width, parseFloat(getComputedStyle(el).maxWidth), el.closest(".history-entry").clientWidth];
          })()
        JS
        width, max_width, entry_width = review
        expect(width).to be_within(0.5).of(max_width)
        expect(max_width).to be < entry_width - 40
        expect(rects("details.answers > summary, details.review > summary").map { |r| r["height"] }).to all(be >= 48)
        expect(rects(".pagination a").map { |r| r["height"] }).to all(be >= 44)
      end
    end

    it "keeps the rail in view while the entries scroll" do
      travel_to(a_weekday) do
        visit_history(width: 1280, height: 900)
        page.execute_script("window.scrollTo(0, 1000)")
        expect(rect(".history-rail")["top"]).to be_within(1).of(24)
      end
    end

    it "lays the desktop grid inside a Pro Max's landscape insets" do
      travel_to(a_weekday) do
        set_safe_area(left: 59, right: 59)
        visit_history(width: 932, height: 430)
        expect(rect(".history-rail")["left"]).to be_within(0.5).of(59)
        expect(page.evaluate_script("document.documentElement.clientWidth") - rect(".history-entries")["right"]).to be_within(0.5).of(59)
        expect(sideways_overflow).to eq(0)
      end
    end
  end
end
