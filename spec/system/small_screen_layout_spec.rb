require "rails_helper"

# Reflow (WCAG 1.4.10) and target size only show up in a real layout.
RSpec.describe "Small screen layout", type: :system do
  def resize(width, height: 844)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: height) }
  end

  def page_width
    page.evaluate_script("document.documentElement.scrollWidth")
  end

  LARGEST = { "text_size" => "140", "line_spacing" => "loose", "font" => "atkinson" }.freeze

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

  def reviewed_day_for(user)
    GenerateDailyExercisesJob.perform_now(user_id: user.id)
    exercise = DailyExercise.find_by!(user: user, date: Date.current)
    keys = exercise.active_section_keys
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: keys.index_with { "an answer long enough to count" },
                          section_ratings: keys.index_with { "right_level" }, submitted_at: Time.current,
                          ai_review: keys.index_with { { "rating" => "solid", "correct" => "Good catch." } })
  end

  def heights(selector)
    page.evaluate_script("Array.from(document.querySelectorAll(#{selector.to_json})).map(el => el.getBoundingClientRect().height)")
  end

  def set_safe_area(left:, right:)
    page.driver.with_playwright_page do |pw|
      pw.context.new_cdp_session(pw).send_message("Emulation.setSafeAreaInsetsOverride", params: { insets: { left: left, right: right } })
    end
  end

  def card_edges(count:)
    edges = page.evaluate_script("Array.from(document.querySelectorAll('main .phone-page > .card')).map(el => { const r = el.getBoundingClientRect(); return [r.left, window.innerWidth - r.right]; })")
    expect(edges.size).to eq(count)
    edges
  end

  def button_and_card_content_widths
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".btn-block")).filter(el => el.checkVisibility()).map(el => {
        const card = el.closest(".card");
        const style = getComputedStyle(card);
        return [el.getBoundingClientRect().width, card.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)];
      })
    JS
  end

  def clipped_button_labels
    page.evaluate_script(<<~JS)
      (() => {
        const context = document.createElement("canvas").getContext("2d");
        return Array.from(document.querySelectorAll(".btn-block")).filter(el => el.checkVisibility()).filter(el => {
          const style = getComputedStyle(el);
          const room = el.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
          if (el.tagName !== "INPUT") return el.scrollWidth > el.clientWidth;
          context.font = style.font;
          return context.measureText(el.value).width > room + 0.5;
        }).map(el => el.value || el.textContent.trim());
      })()
    JS
  end

  def card_gaps
    page.evaluate_script(<<~JS)
      (() => {
        const cards = Array.from(document.querySelectorAll("main .phone-page > .card")).map(el => el.getBoundingClientRect());
        return cards.slice(1).map((card, index) => card.top - cards[index].bottom);
      })()
    JS
  end

  def card_paddings
    page.evaluate_script("Array.from(document.querySelectorAll('main .phone-page > .card')).map(el => getComputedStyle(el).paddingLeft)")
  end

  def card_widths
    page.evaluate_script("Array.from(document.querySelectorAll('main .phone-page > .card')).map(el => el.getBoundingClientRect().width)")
  end

  def hidden_facts(selector)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(#{selector.to_json});
        const box = el.getBoundingClientRect();
        return { hidden: el.hasAttribute("hidden"), visible: el.checkVisibility(), display: getComputedStyle(el).display, size: [box.width, box.height] };
      })()
    JS
  end

  def visible_heights(selector)
    page.evaluate_script("Array.from(document.querySelectorAll(#{selector.to_json})).filter(el => el.checkVisibility()).map(el => el.getBoundingClientRect().height)")
  end

  it "keeps the menu button on screen at 320px, at the default and the largest text size" do
    user = create_fake_provider_user
    resize(320)
    visit_as(user)

    [ {}, { "text_size" => "140", "line_spacing" => "loose", "font" => "atkinson" } ].each do |prefs|
      user.update!(display_preferences: prefs)
      visit learn_path

      expect(page_width).to eq(320)
      expect(page.evaluate_script("document.getElementById('nav-toggle').getBoundingClientRect().right")).to be <= 320
      expect(page.evaluate_script("document.querySelector('.brand-mark').getBoundingClientRect().width")).to be > 0
    end
  end

  it "wraps the submitted day's badge, ratings and review button instead of scrolling sideways" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      GenerateDailyExercisesJob.perform_now(user_id: user.id)
      exercise = DailyExercise.find_by!(user: user, date: Date.current)
      keys = exercise.active_section_keys
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: keys.index_with { "an answer long enough to count" },
                            section_ratings: keys.index_with { "right_level" }, submitted_at: Time.current)
      resize(390)
      visit_as(user)

      expect(page).to have_css(".submit-row")
      expect(page_width).to eq(390)
    end
  end

  it "keeps the review's follow-up field inside the page at 320px with the largest text" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      user.update!(display_preferences: LARGEST)
      reviewed_day_for(user)
      resize(320)
      visit_as(user)

      expect(page).to have_css(".follow-up-input")
      expect(page_width).to eq(320)
    end
  end

  it "keeps the duck's field inside the page at 320px with the largest text" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      user.update!(display_preferences: LARGEST)
      resize(320)
      visit_with_todays_set(user)
      find(".duck-toggle", match: :first).click

      expect(page).to have_css(".duck-input", visible: :visible)
      expect(page_width).to eq(320)
    end
  end

  def width_share(input, form)
    page.evaluate_script(<<~JS)
      (() => {
        const field = document.querySelector(#{input.to_json});
        return field.getBoundingClientRect().width / field.closest(#{form.to_json}).getBoundingClientRect().width;
      })()
    JS
  end

  # A field sharing a row with its buttons must wrap them below rather than shrink to a sliver.
  [ [ 390, {} ], [ 320, LARGEST ] ].each do |width, prefs|
    it "keeps the duck's field wide enough to read at #{width}px#{' with the largest text' if prefs.any?}" do
      travel_to(a_weekday) do
        user = create_fake_provider_user
        user.update!(display_preferences: prefs)
        resize(width)
        visit_with_todays_set(user)
        find(".duck-toggle", match: :first).click

        expect(page).to have_css(".duck-input", visible: :visible)
        expect(width_share(".duck-input", ".duck-form")).to be > 0.6
        expect(page_width).to eq(width)
      end
    end

    it "keeps the follow-up field wide enough to read at #{width}px#{' with the largest text' if prefs.any?}" do
      travel_to(a_weekday) do
        user = create_fake_provider_user
        user.update!(display_preferences: prefs)
        reviewed_day_for(user)
        resize(width)
        visit_as(user)

        expect(page).to have_css(".follow-up-input")
        expect(width_share(".follow-up-input", ".follow-up-form")).to be > 0.6
        expect(page_width).to eq(width)
      end
    end
  end

  it "wraps a long email on Account at 320px with the largest text and the spacing override" do
    user = create_fake_provider_user
    user.update!(email: "averyverylongengineeringaddress@example.com", display_preferences: LARGEST)
    resize(320)
    visit_as(user)
    visit account_path
    apply_text_spacing

    expect(page).to have_text(user.email)
    expect(page_width).to eq(320)
  end

  it "fits the usage card at 320px with the largest text, with every provider row at least 48px" do
    user = create_fake_provider_user
    user.update!(display_preferences: LARGEST)
    { "anthropic" => "1234.56", "gemini" => nil }.each do |provider, cost|
      ApiUsage.create!(user: user, purpose: "review_response", date: Date.current, created_at: Time.current,
                       provider: provider, cost_usd: cost, tokens_in: 0, tokens_out: 0)
    end
    resize(320)
    visit_as(user)
    visit account_path
    apply_text_spacing

    expect(page).to have_text("$1,234.56")
    expect(page_width).to eq(320)
    expect(heights(".api-usage-row").size).to eq(2)
    expect(heights(".api-usage-row")).to all(be >= 48)
  end

  it "fits the authenticator setup, recovery code and second sign-in pages at 320px with the largest text" do
    user = create_fake_provider_user
    user.update!(display_preferences: LARGEST)
    resize(320)
    visit_as(user)

    visit account_authenticator_path
    apply_text_spacing
    expect(page).to have_css("svg.qr-code")
    expect(page_width).to eq(320)

    secret = find(".setup-key").text.delete(" ")
    fill_in "Enter the 6-digit code your app shows", with: current_totp(secret)
    click_button "Turn on"
    expect(page).to have_css(".recovery-code-list li", count: 10)
    apply_text_spacing
    expect(page_width).to eq(320)

    visit account_path
    click_button "Log out"
    visit_as(user)
    expect(page).to have_field("Code from your authenticator app, or a recovery code")
    apply_text_spacing
    expect(page_width).to eq(320)
  end

  it "wraps Progress rows at 320px with the largest text and the spacing override" do
    user = create_fake_provider_user
    user.update!(display_preferences: LARGEST)
    resize(320)
    visit_as(user)
    visit progress_path
    open_every_disclosure
    apply_text_spacing

    expect(page).to have_css(".progress-entry", visible: :visible)
    expect(page_width).to eq(320)
  end

  it "gives the Learn page's back link a 24px target" do
    resize(390)
    visit_as(create_fake_provider_user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

    expect(heights(".learn-back")).to all(be >= 24)
  end

  it "gives the answer form's most-tapped controls a 44px target" do
    travel_to(a_weekday) do
      resize(390)
      visit_with_todays_set(create_fake_provider_user)

      expect(heights("details.section > summary")).to all(be >= 44)
      expect(heights(".rating-btn")).to all(be >= 44)
      expect(heights("#submit-answers, #nav-toggle")).to all(be >= 44)
    end
  end

  it "keeps a folded section's label where it was, so the larger target costs no space" do
    travel_to(a_weekday) do
      resize(390)
      visit_with_todays_set(create_fake_provider_user)

      offset = page.evaluate_script(<<~JS)
        (() => {
          const section = document.querySelector("details.section");
          section.open = false;
          return document.querySelector(".section-title").getBoundingClientRect().top - section.getBoundingClientRect().top;
        })()
      JS

      padding_top = page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('details.section')).paddingTop)")
      expect(offset).to be_within(1).of(padding_top)
    end
  end

  it "offers a skip link as the first stop that moves focus to the main content" do
    resize(390)
    visit_as(create_fake_provider_user)
    visit learn_path

    page.driver.with_playwright_page { |pw| pw.keyboard.press("Tab") }
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Skip to content")
    expect(page.evaluate_script("document.activeElement.getBoundingClientRect().top")).to be >= 0

    page.driver.with_playwright_page { |pw| pw.keyboard.press("Enter") }
    expect(page.evaluate_script("document.activeElement.id")).to eq("main-content")
  end

  describe "Account's phone layout" do
    let(:user) { create_fake_provider_user.tap { |user| user.update!(reminder_level: "ready_and_nudges") } }

    around do |example|
      with_push_credentials { example.run }
    end

    before do
      user.push_subscriptions.create!(endpoint: "https://web.push.apple.com/installed", p256dh_key: "p256dh", auth_key: "auth")
      stub_push_apis(permission: "granted")
    end

    def visit_account_with_every_card
      secret, = enroll_second_factor(user)
      visit_as(user)
      fill_in "Code from your authenticator app, or a recovery code", with: current_totp(secret)
      click_button "Verify"
      visit account_path
      wait_for_js
    end

    [ [ 390, {} ], [ 320, LARGEST ] ].each do |width, prefs|
      it "lays Account out in 16px-margined cards with 48px buttons at #{width}px#{' with the largest text' if prefs.any?}" do
        user.update!(display_preferences: prefs)
        resize(width)
        visit_account_with_every_card
        apply_text_spacing if prefs.any?

        expect(page_width).to eq(width)
        card_edges(count: 7).each { |edges| expect(edges).to all(be_within(0.5).of(16)) }
        expect(visible_heights(".btn-block").size).to eq(7)
        expect(visible_heights(".btn-block")).to all(be >= 48)
        button_and_card_content_widths.each { |button, content| expect(button).to be_within(1).of(content) }
        expect(clipped_button_labels).to eq([])
        expect(heights(".switch-row").size).to eq(1)
        expect(heights(".switch-row")).to all(be >= 48)
        expect(card_paddings).to all(eq("16px"))
        expect(card_gaps).to all(be_within(0.5).of(16))
      end
    end

    it "keeps the repair button hidden and out of the layout when nothing needs repair" do
      resize(390)
      visit_account_with_every_card

      %w[#push-repair #push-repair-status].each do |selector|
        expect(hidden_facts(selector)).to eq("hidden" => true, "visible" => false, "display" => "none", "size" => [ 0, 0 ])
      end
    end

    it "keeps any hidden element on the page out of the layout, whatever its class" do
      resize(390)
      visit_account_with_every_card
      page.execute_script(%(document.querySelector(".api-usage").insertAdjacentHTML("beforeend", '<div id="hidden-probe" class="api-usage-row" hidden>x</div>')))

      expect(hidden_facts("#hidden-probe")).to eq("hidden" => true, "visible" => false, "display" => "none", "size" => [ 0, 0 ])
    end

    it "styles the status line, code labels and usage text as card notes" do
      resize(390)
      visit_account_with_every_card

      notes = page.evaluate_script(%(Array.from(document.querySelectorAll("#push-repair-status, .authenticator-form label, .api-usage p")).map(el => el.classList.contains("card-note"))))
      expect(notes.size).to be >= 4
      expect(notes).to all(be true)
    end

    it "keeps Account's cards clear of a 44px notch in portrait" do
      resize(390)
      set_safe_area(left: 44, right: 44)
      visit_account_with_every_card

      card_edges(count: 7).each { |edges| expect(edges).to all(be_within(0.5).of(44)) }
      expect(page_width).to eq(390)
    end

    it "puts Account's cards at a 20px inset, not at 16px" do
      resize(390)
      set_safe_area(left: 20, right: 0)
      visit_account_with_every_card

      card_edges(count: 7).each do |left, right|
        expect(left).to be_within(0.5).of(20)
        expect(right).to be_within(0.5).of(16)
      end
    end

    it "keeps Account's cards 480px wide and centered in landscape with a notch" do
      resize(844, height: 390)
      set_safe_area(left: 47, right: 47)
      visit_account_with_every_card

      expect(card_widths).to all(be_within(0.5).of(480))
      card_edges(count: 7).each { |left, right| expect(left).to be_within(1).of(right) }
    end

    it "toggles the nudges switch from a tap on its text" do
      resize(390)
      visit_account_with_every_card
      was_checked = find("input.switch").checked?

      find(".switch-row").click(x: 4, y: 4)

      expect(find("input.switch").checked?).to eq(!was_checked)
    end
  end
end
