require "rails_helper"

RSpec.describe "Answer focus layout", type: :system do
  [ 1, 2 ].each do |zoom|
    it "keeps a keyboard-focused answer clear of completion controls in a short phone viewport at #{zoom * 100}% zoom" do
      travel_to(a_weekday) do
        resize(390, height: 400)
        visit_with_todays_set(create_fake_provider_user)
        page.execute_script("document.documentElement.style.zoom = #{zoom}")
        page.execute_script(<<~JS)
          const target = document.querySelector("textarea[data-field]");
          const stops = [...document.querySelectorAll("a[href], button, input, textarea, select, summary, [tabindex='0']")]
            .filter(element => !element.disabled && element.checkVisibility());
          stops[stops.indexOf(target) - 1].focus();
        JS
        page.send_keys(:tab)

        expect(page).to have_css("textarea[data-field]:focus")
        expect(page).to have_no_css(".progress-sticky, #progress-label")
        expect(computed_style("#submit-row", "position")).to eq("static")
        expect(computed_style(".today-side", "position")).to eq("static")
        expect(page.evaluate_script(<<~JS)).to be(true)
          (() => {
            const field = document.activeElement.getBoundingClientRect();
            const submit = document.querySelector("#submit-row").getBoundingClientRect();
            return field.top >= 0 && field.top < innerHeight && submit.top >= field.bottom;
          })()
        JS
      end
    end
  end
end
