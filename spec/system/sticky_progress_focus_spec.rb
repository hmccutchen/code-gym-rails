require "rails_helper"

# iOS Safari scrolls a field it moves focus to up to the top edge, where the
# dashboard's sticky progress bar would cover it. Chrome centers the field
# instead, so this scrolls with the top-edge alignment Safari uses.
RSpec.describe "Sticky progress bar and focus", type: :system do
  it "keeps a focused answer and its focus ring below the bar at phone width" do
    travel_to(a_weekday) do
      page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
      visit_with_todays_set(create_fake_provider_user)

      textarea = find('textarea[data-field="pattern"]')
      textarea.click
      page.execute_script(<<~JS)
        const field = document.activeElement;
        window.scrollBy(0, field.getBoundingClientRect().top + 40);
        field.scrollIntoView({ block: "nearest" });
      JS

      bar_bottom, ring_top = page.evaluate_script(<<~JS)
        (() => {
          const field = document.activeElement;
          const style = getComputedStyle(field);
          const ringReach = parseFloat(style.outlineWidth) + parseFloat(style.outlineOffset);
          return [document.querySelector(".progress-sticky").getBoundingClientRect().bottom,
                  field.getBoundingClientRect().top - ringReach];
        })()
      JS

      # Scroll positions snap to whole pixels, so allow a sub-pixel overlap.
      expect(ring_top).to be >= bar_bottom - 0.5
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
    end
  end
end
