require "rails_helper"

# Playwright cannot emulate display-mode (see spec/requests/pwa_spec.rb), so
# "standalone" here is the layout's rule forced on before the page's own
# scripts run: the one thing the pull-to-refresh script reads. pwa_spec pins
# that only the standalone media query sets that rule in a real launch.
RSpec.describe "Pull to refresh", type: :system do
  let(:user) { create_fake_provider_user }

  FORCE_STANDALONE = <<~JS.freeze
    new MutationObserver((_, observer) => {
      if (!document.head) return;
      const style = document.createElement("style");
      style.textContent = "body .pull-refresh { display: flex; }";
      document.head.appendChild(style);
      observer.disconnect();
    }).observe(document, { childList: true, subtree: true });
  JS

  def launch_standalone
    page.driver.with_playwright_page { |pw| pw.add_init_script(script: FORCE_STANDALONE) }
  end

  # Drives the document's touch listeners with synthetic events: a real finger
  # needs a touch-enabled context, and these listeners only read positions.
  # Each step is [type, y] for one finger, or [type, y, fingers].
  def touch(steps, from: "body")
    page.execute_script(<<~JS, from, steps)
      const [selector, steps] = arguments;
      const target = document.querySelector(selector);
      const finger = (id, y) => new Touch({ identifier: id, target, clientX: 100 * id, clientY: y });
      steps.forEach(([type, y, fingers = 1]) => {
        const active = type === "touchend" ? [] : Array.from({ length: fingers }, (_, i) => finger(i + 1, y));
        target.dispatchEvent(new TouchEvent(type, {
          bubbles: true, cancelable: true, touches: active, changedTouches: [finger(1, y)]
        }));
      });
    JS
  end

  def pull(distance, from: "body")
    moves = (1..5).map { |step| [ "touchmove", 100 + distance * step / 5 ] }
    touch([ [ "touchstart", 100 ], *moves, [ "touchend", 100 + distance ] ], from: from)
  end

  def indicator(script)
    page.evaluate_script("document.getElementById('pull-refresh').#{script}")
  end

  def content(script)
    page.evaluate_script("document.querySelector('[data-pull-content]').#{script}")
  end

  def top_of(selector)
    page.evaluate_script("document.querySelector('#{selector}').getBoundingClientRect().top")
  end

  def mark_page
    page.execute_script("window.__beforePull = true")
  end

  def reloaded?
    Timeout.timeout(5) { sleep 0.1 until page.evaluate_script("window.__beforePull === undefined") }
    true
  rescue Timeout::Error
    false
  end

  def still_the_same_page?
    sleep 0.5
    page.evaluate_script("window.__beforePull === true")
  end

  it "reloads the page when released past the threshold" do
    launch_standalone
    visit_as(user)
    visit learn_path
    mark_page

    pull(200)

    expect(reloaded?).to be(true)
    expect(page).to have_current_path(learn_path)
  end

  it "drags the page content down under a nav that stays put, revealing the spinner between them" do
    launch_standalone
    visit_as(user)
    visit learn_path
    nav_top = top_of("body > nav")
    content_top = top_of("[data-pull-content]")

    touch([ [ "touchstart", 100 ], [ "touchmove", 200 ], [ "touchmove", 300 ] ])

    expect(top_of("body > nav")).to eq(nav_top)
    expect(top_of("[data-pull-content]")).to be > content_top + 60
    spinner = page.evaluate_script("document.getElementById('pull-refresh').getBoundingClientRect().toJSON()")
    expect(spinner["top"]).to be >= page.evaluate_script("document.querySelector('body > nav').getBoundingClientRect().bottom")
    expect(spinner["bottom"]).to be <= top_of("[data-pull-content]")
    expect(indicator("classList.contains('is-ready')")).to be(true)
  end

  it "resists the pull the further it goes, like a native rubber band" do
    launch_standalone
    visit_as(user)
    visit learn_path

    rest = top_of("[data-pull-content]")
    touch([ [ "touchstart", 100 ], [ "touchmove", 200 ] ])
    after_first_hundred = top_of("[data-pull-content]")
    touch([ [ "touchmove", 300 ] ])
    after_second_hundred = top_of("[data-pull-content]")
    touch([ [ "touchcancel", 300 ] ])

    expect(after_first_hundred - rest).to be < 100
    expect(after_second_hundred - after_first_hundred).to be < after_first_hundred - rest
  end

  it "cancels a pull released before the threshold, putting the content back" do
    launch_standalone
    visit_as(user)
    visit learn_path
    mark_page

    pull(60)

    expect(still_the_same_page?).to be(true)
    expect(indicator("classList.contains('is-ready')")).to be(false)
    expect(indicator("style.transform")).to eq("")
    expect(content("style.transform")).to eq("")
  end

  it "does nothing in a browser tab, which has its own pull to refresh" do
    visit_as(user)
    visit learn_path
    mark_page

    pull(200)

    expect(page.evaluate_script("getComputedStyle(document.getElementById('pull-refresh')).display")).to eq("none")
    expect(still_the_same_page?).to be(true)
  end

  it "does not start while a text field has focus, so a pending autosave is not cut off" do
    launch_standalone
    visit_as(user)
    visit learn_path
    find("#learn-filter-input").click
    mark_page

    pull(200)

    expect(still_the_same_page?).to be(true)
  end

  it "does not start while a form is inert, as the dashboard's is during submission" do
    launch_standalone
    visit_as(user)
    visit learn_path
    page.execute_script("const form = document.createElement('form'); form.inert = true; document.body.appendChild(form)")
    mark_page

    pull(200)

    expect(still_the_same_page?).to be(true)
  end

  it "puts the indicator away when a second finger lands mid-pull" do
    launch_standalone
    visit_as(user)
    visit learn_path
    mark_page

    touch([ [ "touchstart", 100 ], [ "touchmove", 200 ], [ "touchmove", 300 ] ])
    expect(indicator("classList.contains('is-ready')")).to be(true)

    touch([ [ "touchstart", 300, 2 ], [ "touchend", 300 ] ])

    expect(indicator("classList.contains('is-ready')")).to be(false)
    expect(content("style.transform")).to eq("")
    expect(still_the_same_page?).to be(true)
  end

  it "leaves a pull inside a scrolled inner area to scroll that area" do
    launch_standalone
    visit_as(user)
    visit learn_path
    page.execute_script(<<~JS)
      const panel = document.createElement("div");
      panel.id = "panel";
      panel.style.cssText = "height: 100px; overflow: auto";
      panel.innerHTML = '<p id="panel-text" style="height: 400px">Scrolled content</p>';
      document.body.prepend(panel);
      panel.scrollTop = 50;
    JS
    mark_page

    pull(200, from: "#panel-text")

    expect(page.evaluate_script("window.scrollY")).to eq(0)
    expect(still_the_same_page?).to be(true)
  end

  it "waits for a pending save before reloading" do
    launch_standalone
    visit_as(user)
    visit learn_path
    page.execute_script("window.__saving = true; window.CodeGymSaveStatus.watch(() => window.__saving)")
    mark_page

    pull(200)

    expect(still_the_same_page?).to be(true)
    expect(indicator("classList.contains('is-refreshing')")).to be(true)
    expect(content("style.transform")).to eq("translateY(64px)")

    page.execute_script("window.__saving = false")

    expect(reloaded?).to be(true)
  end

  # The page the spinner was drawn on is replaced by the reload, so the new
  # page has to pick the spinner up for the refresh to read as one.
  it "opens the reloaded page with the content held down and the spinner turning, then settles" do
    launch_standalone
    visit_as(user)
    visit learn_path
    page.execute_script("sessionStorage.setItem('codegym:pull-refreshed', '1')")

    visit learn_path

    expect(indicator("classList.contains('is-refreshing')")).to be(true)
    expect(content("style.transform")).to eq("translateY(64px)")
    Timeout.timeout(5) { sleep 0.1 while indicator("classList.contains('is-refreshing')") }
    expect(indicator("style.transform")).to eq("")
    expect(content("style.transform")).to eq("")
    expect(page.evaluate_script("sessionStorage.getItem('codegym:pull-refreshed') === null")).to be(true)
  end

  it "leaves the note for the reloaded page when a pull reloads" do
    launch_standalone
    visit_as(user)
    visit learn_path
    mark_page
    page.execute_script(<<~JS)
      const setItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function (key, value) {
        if (key === "codegym:pull-refreshed") window.name = "noted";
        return setItem.call(this, key, value);
      };
    JS

    pull(200)

    expect(reloaded?).to be(true)
    expect(page.evaluate_script("window.name")).to eq("noted")
  end

  it "keeps a dashboard answer typed just before the pull", with_csrf: true do
    answer = "The loop re-runs the orders query per customer; load the totals once."

    travel_to(a_weekday) do
      launch_standalone
      visit_with_todays_set(user)
      textarea = find('textarea[data-field="code_review"]')
      textarea.fill_in(with: answer)
      # fill_in scrolls the answer into view, and a pull only starts at the top.
      page.execute_script("document.activeElement.blur(); window.scrollTo(0, 0)")
      mark_page

      pull(200)

      expect(reloaded?).to be(true)
      expect(find('textarea[data-field="code_review"]').value).to eq(answer)
    end
  end
end
