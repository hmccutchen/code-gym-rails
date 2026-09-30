require "rails_helper"

# Fields and sliders share one keyboard focus ring. A page rule that sets
# `outline: none` on focus once hid it on the Setup sliders, so each kind of
# control is focused from the keyboard here and checked for the ring.
RSpec.describe "Focus ring", type: :system do
  let(:user) { create_fake_provider_user }
  let(:ring_color) { "rgb(201, 192, 255)" }

  def tab_to(selector)
    page.execute_script(<<~JS)
      const target = document.querySelector(#{selector.to_json});
      const stops = [...document.querySelectorAll("a[href], button, input, textarea, select, summary, [tabindex='0']")]
        .filter(el => !el.disabled && el.checkVisibility());
      stops[stops.indexOf(target) - 1].focus();
    JS
    page.send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.matches(#{selector.to_json})")).to be(true)
  end

  def outline_of_focused
    page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.activeElement);
        return [style.outlineStyle, style.outlineWidth, style.outlineColor, style.outlineOffset];
      })()
    JS
  end

  # The thumb is a pseudo-element, which computed styles do not reach, so the
  # ring is looked for in a screenshot of the slider.
  def ring_pixels_around_focused_slider
    shot = nil
    page.driver.with_playwright_page do |pw|
      box = pw.evaluate("(() => { const r = document.activeElement.getBoundingClientRect(); return { x: r.x - 6, y: r.y - 6, width: r.width + 12, height: r.height + 12 }; })()")
      shot = Base64.strict_encode64(pw.screenshot(clip: box))
    end
    page.evaluate_async_script(<<~JS, shot)
      const [data, done] = arguments;
      const image = new Image();
      image.onload = () => {
        const canvas = document.createElement("canvas");
        canvas.width = image.width; canvas.height = image.height;
        const context = canvas.getContext("2d");
        context.drawImage(image, 0, 0);
        const pixels = context.getImageData(0, 0, image.width, image.height).data;
        let count = 0;
        for (let i = 0; i < pixels.length; i += 4) {
          if (Math.abs(pixels[i] - 201) < 12 && Math.abs(pixels[i + 1] - 192) < 12 && Math.abs(pixels[i + 2] - 255) < 12) count++;
        }
        done(count);
      };
      image.src = "data:image/png;base64," + data;
    JS
  end

  it "rings a focused answer textarea" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      tab_to('textarea[data-field="code_review"]')

      expect(outline_of_focused).to eq([ "solid", "2px", ring_color, "2px" ])
    end
  end

  it "rings the Setup fields, and a slider on its thumb rather than its whole track" do
    visit_as(user)
    visit setup_path

    tab_to("input[type='password']")
    expect(outline_of_focused).to eq([ "solid", "2px", ring_color, "2px" ])

    find("#exercise-mix summary").click
    tab_to("input[type='range']:not(:disabled)")
    expect(outline_of_focused.first).to eq("none")
    expect(ring_pixels_around_focused_slider).to be > 20
  end

  # Login has no stored preference and follows the device, so each palette's
  # ring is checked under the scheme that selects it.
  it "rings the login fields in the dark palette" do
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "dark") }
    visit login_path
    tab_to("input[type='email']")

    expect(outline_of_focused).to eq([ "solid", "2px", ring_color, "2px" ])
  end

  it "rings the login fields in the light palette when the device asks for it" do
    page.driver.with_playwright_page { |pw| pw.emulate_media(colorScheme: "light") }
    visit login_path
    tab_to("input[type='email']")

    expect(outline_of_focused).to eq([ "solid", "2px", "rgb(75, 55, 194)", "2px" ])
  end
end
