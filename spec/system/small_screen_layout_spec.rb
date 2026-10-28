require "rails_helper"

# Reflow (WCAG 1.4.10) and target size only show up in a real layout.
RSpec.describe "Small screen layout", type: :system do
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
      user.update!(display_preferences: LayoutHelpers::LARGEST_TEXT)
      reviewed_day_for(user)
      resize(320)
      visit_as(user)

      expect(page).to have_css(".follow-up-input")
      expect(page_width).to eq(320)
    end
  end

  [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
    it "keeps History inside a #{width}px screen#{' with the largest text' if prefs.any?} when a question, review or answer holds a long path" do
      travel_to(a_weekday) do
        user = create_fake_provider_user
        user.update!(display_preferences: prefs)
        long_path = "app/controllers/push_subscriptions_controller_with_a_longer_name.rb"
        response = reviewed_day_for(user)
        response.update!(answers: response.answers.transform_values { "See #{long_path} here." },
                         ai_review: response.ai_review.transform_values { |review| review.merge("correct" => "Check #{long_path} first.") })
        exercise = response.daily_exercise
        exercise.update!(problem_set: exercise.problem_set.to_h do |key, data|
          [ key, data.is_a?(Hash) ? data.merge("question" => "Why does #{long_path} fail?", "scenario" => "Open #{long_path}.") : data ]
        end)
        resize(width)
        visit_as(user)
        visit history_path

        expect(page).to have_css(".review-block")
        expect(page_width).to eq(width)
        open_every_disclosure
        expect(page_width).to eq(width)
      end
    end
  end

  it "keeps the submitted dashboard inside a 390px screen when its review holds a long path" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      response = reviewed_day_for(user)
      response.update!(ai_review: response.ai_review.transform_values { |review| review.merge("correct" => "Check app/controllers/push_subscriptions_controller_with_a_longer_name.rb first.") })
      resize(390)
      visit_as(user)

      expect(page).to have_css(".review-block")
      expect(page_width).to eq(390)
    end
  end

  it "keeps the duck's field inside the page at 320px with the largest text" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      user.update!(display_preferences: LayoutHelpers::LARGEST_TEXT)
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
  [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
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
    user.update!(email: "averyverylongengineeringaddress@example.com", display_preferences: LayoutHelpers::LARGEST_TEXT)
    resize(320)
    visit_as(user)
    visit account_path
    apply_text_spacing

    expect(page).to have_text(user.email)
    expect(page_width).to eq(320)
  end

  it "fits the usage card at 320px with the largest text, with every provider row at least 48px" do
    user = create_fake_provider_user
    user.update!(display_preferences: LayoutHelpers::LARGEST_TEXT)
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
    user.update!(display_preferences: LayoutHelpers::LARGEST_TEXT)
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
    user.update!(display_preferences: LayoutHelpers::LARGEST_TEXT)
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

    [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
      it "lays Account out in 16px-margined cards with 48px buttons at #{width}px#{' with the largest text' if prefs.any?}" do
        user.update!(display_preferences: prefs)
        resize(width)
        visit_account_with_every_card
        apply_text_spacing if prefs.any?

        expect(page_width).to eq(width)
        card_edges(count: 7).each { |edges| expect(edges).to all(be_within(0.5).of(16)) }
        expect(visible_heights(".btn-block").size).to eq(6)
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
      wait_for { user.reload.reminders_ready_and_nudges? != was_checked }
    end
  end

  describe "Settings' phone layout" do
    def visit_settings_open(user)
      visit_as(user)
      visit setup_path
      wait_for_js
      open_every_disclosure
    end

    def rem(multiple)
      multiple * page.evaluate_script("parseFloat(getComputedStyle(document.documentElement).fontSize)")
    end

    def value_row_facts
      page.evaluate_script(<<~JS)
        (() => {
          const context = document.createElement("canvas").getContext("2d");
          return Array.from(document.querySelectorAll(".value-row")).filter(row => row.checkVisibility()).map(row => {
            const value = row.querySelector(".value-row-value");
            const select = row.querySelector("select");
            const card = row.closest(".card");
            const cardStyle = getComputedStyle(card);
            const contentRight = card.getBoundingClientRect().left + card.clientLeft + card.clientWidth - parseFloat(cardStyle.paddingRight);
            const selected = select.options[select.selectedIndex].text;
            const selectStyle = getComputedStyle(select);
            context.font = selectStyle.font;
            const room = select.clientWidth - parseFloat(selectStyle.paddingLeft) - parseFloat(selectStyle.paddingRight);
            return [
              row.getBoundingClientRect().height,
              value.textContent,
              selected,
              value.scrollWidth > value.clientWidth || value.scrollHeight > value.clientHeight,
              row.getBoundingClientRect().right > contentRight + 0.5,
              parseFloat(selectStyle.opacity) > 0 && context.measureText(selected).width > room
            ];
          });
        })()
      JS
    end

    def connection_text_facts
      page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector("main .phone-page > .card");
          const style = getComputedStyle(card);
          const box = card.getBoundingClientRect();
          const contentRight = box.left + card.clientLeft + card.clientWidth - parseFloat(style.paddingRight);
          const guide = card.querySelector(".key-guide");
          return {
            intro: parseFloat(getComputedStyle(card.querySelector(".card-heading + .card-note")).marginBottom),
            guide_tops: guide ? Array.from(guide.children).slice(1).map(el => parseFloat(getComputedStyle(el).marginTop)) : [],
            guide_lists: guide ? Array.from(guide.querySelectorAll("ol, ul")).map(el => parseFloat(getComputedStyle(el).paddingLeft)) : [],
            past_edge: Array.from(card.querySelectorAll("*")).filter(el => el.checkVisibility() && el.getBoundingClientRect().right > contentRight + 0.5).map(el => el.outerHTML.slice(0, 80))
          };
        })()
      JS
    end

    def mix_control_facts
      page.evaluate_script(<<~JS)
        (() => {
          const card = document.getElementById("exercise-mix");
          const style = getComputedStyle(card);
          const contentRight = card.getBoundingClientRect().left + card.clientLeft + card.clientWidth - parseFloat(style.paddingRight);
          const controls = Array.from(card.querySelectorAll(".mix-level, .switch-row, input[type=range], .kind-about > summary, .mix-difficulty")).filter(el => el.checkVisibility());
          return {
            count: controls.length,
            levels: Array.from(card.querySelectorAll(".mix-level")).filter(el => el.checkVisibility()).map(el => el.getBoundingClientRect().height),
            past_edge: controls.filter(el => el.getBoundingClientRect().right > contentRight + 0.5).map(el => el.outerHTML.slice(0, 80))
          };
        })()
      JS
    end

    def heading_and_tag
      page.evaluate_script(<<~JS)
        (() => {
          const card = document.querySelector("main .phone-page > .card");
          const style = getComputedStyle(card);
          const contentLeft = card.getBoundingClientRect().left + card.clientLeft + parseFloat(style.paddingLeft);
          const contentRight = contentLeft + card.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
          const lineHeight = el => { const s = getComputedStyle(el); const value = parseFloat(s.lineHeight); return Number.isNaN(value) ? parseFloat(s.fontSize) * 1.2 : value; };
          const fact = el => { const r = el.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height, line: lineHeight(el) }; };
          const tag = card.querySelector(".card-heading > .card-tag");
          return { h2: fact(card.querySelector(".card-heading > h2")), tag: fact(tag), content: [contentLeft, contentRight],
                   tag_overflows: tag.scrollWidth > tag.clientWidth };
        })()
      JS
    end

    def segment_facts(selector)
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll(#{"#{selector} .segment".to_json})).map(el => { const r = el.getBoundingClientRect(); return [r.height, Math.round(r.top)]; })
      JS
    end

    def three_key_user
      create_fake_provider_user.tap do |user|
        user.update!(api_keys: { "fake" => "fake-test-key", "gemini" => "AIzaSyExampleKey12345", "openai" => "sk-proj-Ab8RN6J5yPUsY9Sw" })
      end
    end

    [ [ 390, {} ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
      describe "at #{width}px#{' with the largest text' if prefs.any?}" do
        it "lays Settings' first two cards out" do
          user = create_fake_provider_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)
          apply_text_spacing if prefs.any?

          expect(page_width).to eq(width)
          card_edges(count: 4).each { |edges| expect(edges).to all(be_within(0.5).of(16)) }
          expect(card_paddings).to all(eq("16px"))
          expect(card_gaps).to all(be_within(0.5).of(16))
          expect(visible_heights(".value-row").size).to eq(3)
          expect(visible_heights(".value-row")).to all(be >= 52)
          expect(visible_heights(".btn-block").size).to eq(1)
          expect(visible_heights(".btn-block")).to all(be >= 48)
          button_and_card_content_widths.each { |button, content| expect(button).to be_within(1).of(content) }
          expect(clipped_button_labels).to eq([])
          expect(heights("details.card > summary").size).to eq(2)
          expect(heights("details.card > summary")).to all(be >= 48)
          expect(heights("#level-suggestions-switch .switch-row")).to all(be >= 48)
          expect(heights("#level-suggestions-switch .switch-row").size).to eq(1)
        end

        it "keeps the switch's note and empty status line at their card spacing" do
          user = create_fake_provider_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)

          status, hint_margin = page.evaluate_script(<<~JS)
            (() => {
              const status = document.querySelector("#level-suggestions-switch .switch-status");
              const style = getComputedStyle(status);
              return [[status.getBoundingClientRect().height, style.marginTop, style.marginBottom],
                      parseFloat(getComputedStyle(document.getElementById("level-suggestions-hint")).marginBottom)];
            })()
          JS
          expect(status).to eq([ 0, "0px", "0px" ])
          expect(hint_margin).to be_within(0.5).of(rem(0.75))
        end

        it "keeps every Exercise mix control inside its card with the mix and every About open" do
          user = create_fake_provider_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)
          apply_text_spacing if prefs.any?

          facts = mix_control_facts
          expect(page_width).to eq(width)
          expect(facts["count"]).to be > 0
          expect(facts["levels"]).not_to be_empty
          expect(facts["levels"]).to all(be >= 48)
          expect(facts["past_edge"]).to eq([])
        end

        it "keeps the page inside the screen with a suggested kind" do
          user = create_fake_provider_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_as(user)
          visit setup_path(suggested: %w[code_review], suggested_level: "junior")
          wait_for_js
          open_every_disclosure
          apply_text_spacing if prefs.any?

          expect(page).to have_css("#exercise-mix .mix-level", visible: :visible)
          expect(page_width).to eq(width)
        end

        it "keeps the Exercise mix's hidden notes out of the layout" do
          user = create_fake_provider_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)

          checked = [ "#mix-ladder-preparation", ".mix-last-note" ].select { |selector| page.has_css?(selector, visible: :all, wait: 0) }
          checked.each do |selector|
            facts = hidden_facts(selector)
            next unless facts["hidden"]

            expect(facts).to include("visible" => false, "display" => "none", "size" => [ 0, 0 ])
          end
          expect(checked).not_to be_empty
        end

        it "shows and preserves the saved unlisted time zone" do
          user = create_fake_provider_user(time_zone: "Europe/London")
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)

          expect(find("#tz-select", visible: :all).ancestor(".value-row").find(".value-row-value", visible: :all).text(:all))
            .to eq("Europe/London")
          expect(find("#tz-select", visible: :all).value).to eq("Europe/London")
          expect(user.reload.time_zone).to eq("Europe/London")
        end

        {
          "a user with no key and no exercises" => -> { User.create!(email: "no-key@example.com", name: "No key", time_zone: "UTC", track_chosen_at: Time.current) },
          "an active trial user" => -> { create_trial_user }
        }.each do |who, build|
          it "keeps Connection's text spaced and inside the card for #{who}" do
            user = instance_exec(&build)
            user.update!(display_preferences: prefs)
            resize(width)
            visit_settings_open(user)

            expect(connection_text_facts["intro"]).to be_within(0.5).of(rem(0.75))
            apply_text_spacing if prefs.any?
            facts = connection_text_facts
            expect(facts["guide_tops"]).to all(be_within(0.5).of(rem(0.5)))
            expect(facts["guide_lists"]).to all(be_within(0.5).of(rem(1.25)))
            expect(facts["guide_tops"]).not_to be_empty if who.include?("no key")
            expect(facts["past_edge"]).to eq([])
          end
        end

        spacings = prefs.any? ? [ false, true ] : [ false ]
        spacings.each do |spacing|
          it "keeps the Connection tag on one line#{' with the spacing override' if spacing}" do
            user = create_fake_provider_user
            user.update!(display_preferences: prefs)
            resize(width)
            visit_settings_open(user)
            apply_text_spacing if spacing
            facts = heading_and_tag

            expect(facts["h2"]["height"]).to be <= facts["h2"]["line"] + 1
            expect(facts["tag"]["height"]).to be <= facts["tag"]["line"] + 1
            expect(facts["tag"]["left"]).to be >= facts["content"][0] - 0.5
            expect(facts["tag"]["right"]).to be <= facts["content"][1] + 0.5
            expect(facts["tag_overflows"]).to be(false)
            if prefs.any?
              expect(facts["tag"]["top"]).to be >= facts["h2"]["bottom"] - 0.5
            else
              expect((facts["tag"]["top"] - facts["h2"]["top"]).abs).to be <= facts["h2"]["line"]
            end
          end
        end

        it "draws provider and Daily sections segments" do
          user = three_key_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)
          apply_text_spacing if prefs.any?

          { "#provider-choice" => 3, "#daily-sections" => User::DAILY_SECTION_COUNTS.size + 1 }.each do |control, count|
            facts = segment_facts(control)
            expect(facts.size).to eq(count)
            expect(facts.map(&:first)).to all(be >= 44)
            expect(facts.map(&:last).uniq.size).to eq(1)
          end
        end

        it "shows the failure banner without scrolling" do
          user = create_fake_provider_user
          user.update!(display_preferences: prefs)
          resize(width)
          visit_settings_open(user)
          page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
          fail_requests_to(profile_path)

          find("#daily-sections .segment", text: "2").click
          expect(page).to have_css("#save-status", visible: :visible)

          banner, focused, viewport = page.evaluate_script(<<~JS)
            (() => {
              const box = el => { const r = el.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom]; };
              return [box(document.getElementById("save-status")), box(document.activeElement), window.innerHeight];
            })()
          JS
          expect(banner[1]).to be >= 0
          expect(banner[3]).to be <= viewport
          overlaps = banner[0] < focused[2] && focused[0] < banner[2] && banner[1] < focused[3] && focused[1] < banner[3]
          expect(overlaps).to be(false)
        end
      end
    end

    it "never clips a long value at 320px with the largest text and the spacing override" do
      [ "America/Phoenix", nil ].each do |zone|
        user = create_fake_provider_user(time_zone: zone)
        user.update!(language: "javascript", skill_level: "principal_engineer", display_preferences: LayoutHelpers::LARGEST_TEXT)
        resize(320)
        visit_settings_open(user)
        apply_text_spacing
        find("#daily-sections .segment", text: "4").click
        expect(page).to have_css("#daily-sections-choice-4", visible: :visible)

        facts = value_row_facts
        expect(facts.size).to eq(5)
        facts.each do |_height, shown, selected, clipped, overflow, too_narrow|
          expect(shown).to eq(selected)
          expect([ clipped, overflow, too_narrow ]).to eq([ false, false, false ])
        end
        expect(page_width).to eq(320)
        visit account_path
        click_button "Log out"
      end
    end

    it "toggles level suggestions from a tap on the switch row's text" do
      user = create_fake_provider_user
      resize(390)
      visit_settings_open(user)

      find("#level-suggestions-switch .switch-row").click(x: 4, y: 4)

      wait_for { user.reload.level_suggestions == false }
    end

    it "applies a provider chosen on its segment when Save key is pressed" do
      user = three_key_user
      resize(390)
      visit_settings_open(user)

      find("#provider-choice .segment", text: "Gemini").click
      click_button "Save key"

      expect(page).to have_no_current_path(setup_path)
      expect(user.reload.provider).to eq("gemini")
    end
  end
end
