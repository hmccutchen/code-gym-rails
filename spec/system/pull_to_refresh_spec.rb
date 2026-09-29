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
  def pull(distance, from: "body")
    page.execute_script(<<~JS, from, distance)
      const [selector, distance] = arguments;
      const target = document.querySelector(selector);
      const touch = (y) => new Touch({ identifier: 1, target, clientX: 100, clientY: y });
      const fire = (type, y, active) => target.dispatchEvent(new TouchEvent(type, {
        bubbles: true, cancelable: true, touches: active ? [touch(y)] : [], changedTouches: [touch(y)]
      }));
      fire("touchstart", 100, true);
      for (let step = 1; step <= 5; step++) fire("touchmove", 100 + distance * step / 5, true);
      fire("touchend", 100 + distance, false);
    JS
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

  it "cancels a pull released before the threshold, putting the indicator away" do
    launch_standalone
    visit_as(user)
    visit learn_path
    mark_page

    pull(60)

    expect(still_the_same_page?).to be(true)
    expect(page.evaluate_script("document.getElementById('pull-refresh').classList.contains('is-ready')")).to be(false)
    expect(page.evaluate_script("document.getElementById('pull-refresh').style.transform")).to eq("")
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
end
