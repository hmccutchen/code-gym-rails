require "rails_helper"

RSpec.describe "Changing the track on Setup", type: :system, with_csrf: true do
  let(:user) do
    create_fake_provider_user.tap do |user|
      user.update_columns(skill_level: "junior",
                          section_kind_levels: ExerciseSection.keys.index_with { "junior" }.merge("pattern" => "senior"),
                          locked_section_kinds: [ "challenge" ])
      DailyExercise.create!(user: user, date: Date.yesterday, generated_at: 1.day.ago,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
    end
  end

  def wait_for(timeout)
    deadline = Time.current + timeout
    sleep 0.1 until yield || Time.current > deadline
  end

  def checked_level(kind)
    find(".mix-difficulty[data-kind='#{kind}'] input[type=radio]:checked", visible: :all).value
  end

  it "updates the Exercise mix without a reload, names the kept sections, and lets the next mix edit save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script("window.sameDocument = true")

    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern")
    expect(find('[data-profile-preferences-target="keptOwnLevel"]').text).to include("Senior", "Junior, locked")
    expect(checked_level("code_review")).to eq("")
    expect(checked_level("pattern")).to eq("senior")
    expect(checked_level("challenge")).to eq("junior")
    expect(user.reload.section_kind_levels).to eq("pattern" => "senior", "challenge" => "junior")

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click

    expect(page).to have_no_css("#save-status", text: /changed in another tab/i, wait: 2)
    expect(page).to have_css(".mix-difficulty[data-kind='code_review'] input[value='senior']:checked", visible: :all)
    wait_for(5) { user.reload.section_kind_levels["code_review"] == "senior" }
    expect(user.reload.section_kind_levels).to include("code_review" => "senior")
    expect(page.evaluate_script("window.sameDocument")).to be(true)
  end

  it "saves a mix edit made just before a track change first, so the track change sees it" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click
    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern")
    wait_for(5) { user.reload.section_kind_levels["code_review"] == "senior" }
    expect(user.reload.section_kind_levels).to eq("code_review" => "senior", "pattern" => "senior", "challenge" => "junior")
    expect(checked_level("code_review")).to eq("senior")
    expect(checked_level("design_comparison")).to eq("")
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
  end

  it "keeps a lock set just before a track change, along with the target it protects" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    find(".mix-difficulty[data-kind='security_review'] .mix-lock-box").click
    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Security")
    wait_for(5) { user.reload.locked_section_kinds.include?("security_review") }
    expect(user.reload).to have_attributes(locked_section_kinds: match_array(%w[challenge security_review]))
    expect(user.section_kind_levels).to include("security_review" => "junior")
    expect(checked_level("security_review")).to eq("junior")
  end

  it "keeps an unsent weight edit without restoring a target the track change cleared" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    page.execute_script(<<~JS)
      const slider = document.querySelector("#weight-security_review");
      slider.value = 0;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern")
    wait_for(5) { user.reload.section_kind_weights == { "security_review" => 0.25 } }
    expect(user.reload.section_kind_weights).to eq("security_review" => 0.25)
    expect(user.section_kind_levels).to eq("pattern" => "senior", "challenge" => "junior")
    expect(checked_level("security_review")).to eq("")
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
  end

  it "forgets a shown suggestion step the track change moved, so a later pick of that kind saves" do
    visit_as(user)
    visit setup_path(suggested: [ "code_review" ], suggested_level: "mid_level")

    find("#skill-level").select("Senior")
    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Challenge")
    find(".mix-difficulty[data-kind='code_review'] input[value='mid_level']").click

    wait_for(5) { user.reload.section_kind_levels["code_review"] == "mid_level" }
    expect(user.reload.section_kind_levels).to include("code_review" => "mid_level")
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
    expect(user.level_suggestion_events.where(kind: "code_review").last.source).to eq("setup_edit")
  end

  it "re-enables Prepare AI guidance once a track change that waited behind a mix save lands" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    expect(page).to have_css("#mix-ladder-preparation:not([hidden])")
    page.execute_script(<<~JS)
      const send = window.fetch;
      let held = false;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (!held && body.includes("section_kind_levels")) {
          held = true;
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1000));
        }
        return send(url, options);
      };
    JS

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click
    sleep 0.6
    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 5)
    expect(page).to have_css("#mix-ladder-preparation button:not([disabled])", visible: :all)
  end

  it "re-enables Prepare AI guidance when the track save that waited behind a mix save fails" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    expect(page).to have_css("#mix-ladder-preparation:not([hidden])")
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("section_kind_levels")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1000));
        }
        if (body.includes("skill_level")) return Promise.reject(new TypeError("offline"));
        return send(url, options);
      };
    JS

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click
    sleep 0.6
    find("#skill-level").select("Mid-level")

    expect(page).to have_css("#save-status", text: /couldn't save/i, wait: 5)
    wait_for(5) { user.reload.section_kind_levels["code_review"] == "senior" }
    expect(page).to have_css("#mix-ladder-preparation button:not([disabled])", visible: :all)
    expect(user.reload.skill_level).to eq("junior")
  end

  it "keeps Prepare AI guidance disabled while a track-only save is in flight" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    expect(page).to have_css("#mix-ladder-preparation button:not([disabled])", visible: :all)
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1500));
        }
        return send(url, options);
      };
    JS

    find("#skill-level").select("Mid-level")

    expect(page).to have_css("#mix-ladder-preparation button[disabled]", visible: :all)
    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 5)
    expect(page).to have_css("#mix-ladder-preparation button:not([disabled])", visible: :all)
  end

  it "keeps a lock ticked while the track save is in flight, along with its level" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1500));
        }
        return send(url, options);
      };
    JS

    find("#skill-level").select("Mid-level")
    sleep 0.3
    find(".mix-difficulty[data-kind='security_review'] .mix-lock-box").click

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 5)
    wait_for(5) { user.reload.locked_section_kinds.include?("security_review") }
    expect(user.reload).to have_attributes(locked_section_kinds: match_array(%w[challenge security_review]))
    expect(user.section_kind_levels).to include("security_review" => "junior")
    expect(user.section_kind_levels).not_to include("code_review")
    expect(checked_level("security_review")).to eq("junior")
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
  end

  it "keeps a target picked after a track change while earlier saves were still queued" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      let held = false;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (!held && body.includes("section_kind_levels")) {
          held = true;
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1500));
        }
        return send(url, options);
      };
    JS

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click
    sleep 0.6
    page.execute_script(<<~JS)
      const slider = document.querySelector("#weight-security_review");
      slider.value = 0;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    find("#skill-level").select("Mid-level")
    find(".mix-difficulty[data-kind='design_comparison'] input[value='mid_level']").click

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 5)
    wait_for(8) { user.reload.section_kind_levels["design_comparison"] == "mid_level" }
    expect(user.reload).to have_attributes(
      skill_level: "mid_level", section_kind_weights: { "security_review" => 0.25 },
      section_kind_levels: { "code_review" => "senior", "design_comparison" => "mid_level", "pattern" => "senior", "challenge" => "junior" }
    )
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
  end

  it "keeps a target picked after a track change while a mix save was already waiting in the queue" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      let held = false;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (!held && body.includes("section_kind_levels")) {
          held = true;
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 2000));
        }
        return send(url, options);
      };
    JS

    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click
    sleep 0.6
    page.execute_script(<<~JS)
      const slider = document.querySelector("#weight-security_review");
      slider.value = 0;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    sleep 0.6
    find("#skill-level").select("Mid-level")
    find(".mix-difficulty[data-kind='design_comparison'] input[value='mid_level']").click

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 6)
    wait_for(8) { user.reload.section_kind_levels["design_comparison"] == "mid_level" }
    expect(user.reload).to have_attributes(
      skill_level: "mid_level", section_kind_weights: { "security_review" => 0.25 },
      section_kind_levels: { "code_review" => "senior", "design_comparison" => "mid_level", "pattern" => "senior", "challenge" => "junior" }
    )
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
  end

  it "does not restore a target the first of two quick track changes cleared" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1200));
        }
        return send(url, options);
      };
    JS

    find("#skill-level").select("Mid-level")
    sleep 0.2
    page.execute_script(<<~JS)
      const slider = document.querySelector("#weight-security_review");
      slider.value = 0;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    expect(page).to have_css("#skill-level:not([disabled])", wait: 5)
    find("#skill-level").select("Senior")

    wait_for(10) { user.reload.skill_level == "senior" && user.section_kind_weights.present? }
    sleep 1
    expect(user.reload).to have_attributes(
      skill_level: "senior", section_kind_weights: { "security_review" => 0.25 },
      section_kind_levels: { "challenge" => "junior" }
    )
    expect(checked_level("security_review")).to eq("")
    expect(page).to have_no_css("#save-status", text: /changed in another tab/i)
  end

  it "keeps a weight moved back while its first save is in flight when the track changes" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      let held = false;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (!held && body.includes("section_kind_weights")) {
          held = true;
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1500));
        }
        return send(url, options);
      };
      window.moveSlider = (value) => {
        const slider = document.querySelector("#weight-security_review");
        slider.value = value === "default" ? slider.defaultValue : value;
        slider.dispatchEvent(new Event("input", { bubbles: true }));
      };
    JS

    page.execute_script(%(moveSlider("0")))
    sleep 0.6
    page.execute_script(%(moveSlider("default")))
    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 6)
    wait_for(8) { user.reload.skill_level == "mid_level" }
    sleep 1
    expect(user.reload.section_kind_weights).to eq({})
    expect(page.evaluate_script(%(document.querySelector("#weight-security_review").value))).to eq(
      page.evaluate_script(%(document.querySelector("#weight-security_review").defaultValue))
    )
  end

  it "resends a mix change whose own save failed when a frozen save follows it" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      let failed = false;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (!failed && body.includes("section_kind_weights")) {
          failed = true;
          return new Promise((resolve, reject) => setTimeout(() => reject(new TypeError("offline")), 1500));
        }
        return send(url, options);
      };
    JS

    page.execute_script(<<~JS)
      const slider = document.querySelector("#weight-security_review");
      slider.value = 0;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    sleep 0.6
    find(".mix-difficulty[data-kind='design_comparison'] input[value='senior']").click
    sleep 0.6
    find("#skill-level").select("Mid-level")

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 6)
    wait_for(8) { user.reload.skill_level == "mid_level" }
    sleep 1
    expect(user.reload.section_kind_weights).to eq("security_review" => 0.25)
    expect(user.section_kind_levels).to include("design_comparison" => "senior")
  end

  it "keeps the last weight across two track changes queued behind a mix save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      let held = false;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (!held && body.includes("section_kind_weights")) {
          held = true;
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 2000));
        }
        return send(url, options);
      };
      window.moveSlider = (index) => {
        const slider = document.querySelector("#weight-security_review");
        slider.value = index;
        slider.dispatchEvent(new Event("input", { bubbles: true }));
      };
    JS

    page.execute_script(%(moveSlider("0")))
    sleep 0.6
    page.execute_script(%(moveSlider("1")))
    find("#skill-level").select("Mid-level")
    page.execute_script(%(moveSlider("0")))
    expect(page).to have_css("#skill-level:not([disabled])", wait: 5)
    find("#skill-level").select("Senior")

    wait_for(10) { user.reload.skill_level == "senior" }
    sleep 1.5
    expect(user.reload.section_kind_weights).to eq("security_review" => 0.25)
    expect(page.evaluate_script(%(document.querySelector("#weight-security_review").value))).to eq("0")
  end

  it "disables the track select while its save is in flight and gives focus back after" do
    visit_as(user)
    visit setup_path
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1200));
        }
        return send(url, options);
      };
    JS

    page.execute_script(<<~JS)
      const select = document.getElementById("skill-level");
      select.focus();
      select.value = "mid_level";
      select.dispatchEvent(new Event("change", { bubbles: true }));
    JS

    expect(page).to have_css("#skill-level[disabled]")
    expect(page).to have_css("#skill-level:not([disabled])", wait: 5)
    expect(page.evaluate_script(%(document.activeElement.id))).to eq("skill-level")
    expect(user.reload.skill_level).to eq("mid_level")
  end

  it "leaves focus where the user moved it during a track save" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1200));
        }
        return send(url, options);
      };
      const select = document.getElementById("skill-level");
      select.focus();
      select.value = "mid_level";
      select.dispatchEvent(new Event("change", { bubbles: true }));
      document.getElementById("weight-security_review").focus();
    JS

    expect(page).to have_css("#skill-level:not([disabled])", wait: 5)
    expect(page.evaluate_script(%(document.activeElement.id))).to eq("weight-security_review")
  end

  it "re-enables the track select when its save fails" do
    visit_as(user)
    visit setup_path
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) return Promise.reject(new TypeError("offline"));
        return send(url, options);
      };
    JS

    find("#skill-level").select("Mid-level")

    expect(page).to have_css("#save-status", text: /couldn't save/i, wait: 5)
    expect(page).to have_css("#skill-level:not([disabled])")
    expect(user.reload.skill_level).to eq("junior")
  end

  it "keeps a level chosen again during a track save, even when it matches the old one" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        const body = options && typeof options.body === "string" ? options.body : "";
        if (body.includes("skill_level")) {
          return new Promise((resolve) => setTimeout(() => resolve(send(url, options)), 1500));
        }
        return send(url, options);
      };
    JS

    find("#skill-level").select("Mid-level")
    find(".mix-difficulty[data-kind='security_review'] input[value='senior']").click
    find(".mix-difficulty[data-kind='security_review'] input[value='junior']").click

    expect(page).to have_css('[data-profile-preferences-target="keptOwnLevel"]', text: "Pattern", wait: 6)
    wait_for(5) { user.reload.section_kind_levels["security_review"] == "junior" }
    expect(user.reload.section_kind_levels).to include("security_review" => "junior")
    expect(user.section_kind_levels).not_to include("code_review")
    expect(checked_level("security_review")).to eq("junior")
  end

  def guide_measurement
    page.evaluate_script(<<~JS)
      (() => {
        const guide = document.querySelector(".key-guide");
        const style = getComputedStyle(guide.querySelector(".hint"));
        return { fontSize: style.fontSize, documentWidth: document.documentElement.scrollWidth };
      })()
    JS
  end

  it "measures the key guide at phone width without hiding content or shrinking type" do
    fresh = User.create!(email: "keyless-#{SecureRandom.hex(3)}@example.com", name: "Keyless", **chosen_track(true))
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    visit_as(fresh)
    visit setup_path
    expect(page).to have_css(".key-guide")

    [ "100", "125", "140" ].each do |size|
      fresh.update!(display_preferences: size == "100" ? {} : { "text_size" => size })
      visit setup_path
      measurement = guide_measurement
      expect(measurement["documentWidth"]).to be <= 390
      expect(measurement["fontSize"].to_f).to be >= 12.8
      expect(page).to have_css(".key-guide li", count: 12)
      expect(page).to have_css(".key-guide p", text: "What it costs.")
    end
  end
end
