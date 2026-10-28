module LayoutHelpers
  LARGEST_TEXT = { "text_size" => "140", "line_spacing" => "loose", "font" => "atkinson" }.freeze
  LAYOUT_WIDTHS = [ 320, 390, 768, 899, 900, 1280, 1920 ].freeze

  def resize(width, height: 844)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: height) }
  end

  def page_width
    page.evaluate_script("document.documentElement.scrollWidth")
  end

  # Against clientWidth, not the window: a classic scrollbar takes its width from the viewport.
  def sideways_overflow
    page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
  end

  # The narrowest width, in 10px steps, at which the nav shows its links in the row rather than the menu button.
  def narrowest_uncollapsed_nav_width(height:)
    width = (320..1400).step(10).find { |candidate|
      resize(candidate, height: height)
      page.has_no_css?("#nav-toggle", visible: :visible, wait: 0)
    }
    width || raise("The nav showed its menu button at every width up to 1400px")
  end

  def nav_row_overflow
    page.evaluate_script(<<~JS)
      (() => {
        const inner = document.querySelector("nav .inner"), root = document.documentElement;
        const contentRight = inner.getBoundingClientRect().right - parseFloat(getComputedStyle(inner).paddingRight);
        const lastLink = Array.from(document.querySelectorAll("nav .nav-links a")).pop();
        const pastGutter = Math.max(0, lastLink.getBoundingClientRect().right - contentRight);
        return { row: inner.scrollWidth - inner.clientWidth, page: root.scrollWidth - root.clientWidth,
                 past_gutter: Math.round(pastGutter * 10) / 10 };
      })()
    JS
  end

  def set_safe_area(left: 0, right: 0, top: 0, bottom: 0)
    page.driver.with_playwright_page do |pw|
      pw.context.new_cdp_session(pw).send_message("Emulation.setSafeAreaInsetsOverride",
                                                  params: { insets: { left: left, right: right, top: top, bottom: bottom } })
    end
  end

  # The WCAG 1.4.12 text-spacing override, the harshest case these pages meet.
  def apply_text_spacing
    page.execute_script(<<~JS)
      const style = document.createElement("style");
      style.textContent = "* { line-height: 1.5 !important; letter-spacing: 0.12em !important; word-spacing: 0.16em !important; } p { margin-bottom: 2em !important; }";
      document.head.appendChild(style);
    JS
  end

  def open_every_disclosure
    page.execute_script("document.querySelectorAll('details').forEach(d => { d.open = true; })")
  end

  def rects(selector)
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(#{selector.to_json})).map(el => {
        const r = el.getBoundingClientRect();
        return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height };
      })
    JS
  end

  def rect(selector) = rects(selector).first

  def client_width = page.evaluate_script("document.documentElement.clientWidth")

  # Each match's distance from the left and right edges of the window.
  def edges(selector)
    rects(selector).map { |r| [ r["left"], client_width - r["right"] ] }
  end

  def computed_style(selector, property)
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

  # Every sheet's 900px rules, wherever they live, switched off and then back on.
  def without_desktop_rules
    toggle_desktop_rules("(min-width: 900px)", "(min-width: 99999px)")
    yield
  ensure
    toggle_desktop_rules("(min-width: 99999px)", "(min-width: 900px)")
  end

  def toggle_desktop_rules(from, to)
    page.execute_script(<<~JS)
      for (const sheet of document.styleSheets) {
        for (const rule of sheet.cssRules) {
          if (rule instanceof CSSMediaRule && rule.media.mediaText === #{from.to_json}) rule.media.mediaText = #{to.to_json};
        }
      }
    JS
  end
end

RSpec.configure do |config|
  config.include LayoutHelpers, type: :system
end
