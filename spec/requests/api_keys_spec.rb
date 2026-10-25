require "rails_helper"

RSpec.describe "ApiKeys", type: :request do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev", track_chosen_at: Time.current) }

  describe "PATCH /setup" do
    it "saves a valid Anthropic key, encrypted, and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("sk-ant-api03-abc123")
      expect(user.provider).to eq("anthropic")
      expect(user.api_key_present?).to be true
    end

    it "saves a valid Gemini key and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "AIzaSyExampleKey12345" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AIzaSyExampleKey12345")
      expect(user.provider).to eq("gemini")
    end

    it "saves a valid Gemini key in Google's newer AQ. format and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg")
      expect(user.provider).to eq("gemini")
    end

    it "saves an OpenAI project key and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.provider).to eq("openai")
    end

    it "detects OpenAI's service-account and legacy key formats" do
      login_as(user)

      [ "sk-svcacct-Ab8RN6J5yPUsY9Sw", "sk-Ab8RN6J5yPUsY9SwLxAS2DYqcYQFIhR9" ].each do |key|
        patch setup_path, params: { api_key: key }
        expect(user.reload.provider).to eq("openai")
      end
    end

    it "never mistakes an Anthropic key for an OpenAI key" do
      expect(OpenaiService.key_pattern).not_to match("sk-ant-api03-Ab8RN6J5yPUsY9SwLxAS2DYq")
    end

    it "saves a valid language preference alongside the API key" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123", language: "javascript" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("javascript")
    end

    it "ignores an invalid language value without blocking the API key save" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123", language: "python" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("ruby_rails")
      expect(user.api_key).to eq("sk-ant-api03-abc123")
    end

    it "defaults to the user's current language when no language param is given" do
      login_as(user)
      user.update!(language: "mixed")

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("mixed")
    end

    it "rejects a key that doesn't look like either provider's key" do
      login_as(user)

      patch setup_path, params: { api_key: "not-a-real-key" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("We don&#39;t recognize this key format")
      expect(user.reload.api_key_present?).to be false
      expect(user.provider).to be_nil
    end

    it "updates only the language when the api_key field is blank and a key already exists" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing" })
      login_as(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("javascript")
      expect(user.api_key).to eq("sk-ant-existing")
    end

    it "keeps the key saved for another provider when a new provider's key is pasted" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing" })
      login_as(user)

      patch setup_path, params: { api_key: "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq" }

      user.reload
      expect(user.provider).to eq("openai")
      expect(user.api_key).to eq("sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq")
      expect(user.api_keys["anthropic"]).to eq("sk-ant-existing")
    end

    it "replaces only the key saved for the pasted key's provider" do
      user.update!(provider: "openai", api_keys: { "anthropic" => "sk-ant-old", "openai" => "sk-proj-kept" })
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-new" }

      user.reload
      expect(user.provider).to eq("anthropic")
      expect(user.api_keys).to eq("anthropic" => "sk-ant-api03-new", "openai" => "sk-proj-kept")
    end

    it "lets a pasted key choose the provider over the posted provider choice" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing", "openai" => "sk-proj-kept" })
      login_as(user)

      patch setup_path, params: { api_key: "AIzaSyExampleKey12345", provider: "openai" }

      expect(user.reload.provider).to eq("gemini")
    end

    it "switches to another provider with a saved key without re-entering it" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing", "openai" => "sk-proj-kept" })
      login_as(user)

      patch setup_path, params: { api_key: "", provider: "openai" }

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t("flash.api_keys.preferences_saved"))
      user.reload
      expect(user.provider).to eq("openai")
      expect(user.api_key).to eq("sk-proj-kept")
      expect(user.api_keys["anthropic"]).to eq("sk-ant-existing")
    end

    it "ignores a provider choice with no saved key" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing" })
      login_as(user)

      patch setup_path, params: { api_key: "", provider: "openai" }

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t("flash.api_keys.no_changes"))
      expect(user.reload.provider).to eq("anthropic")
    end

    it "rejects a language-only update when no key has been set yet" do
      login_as(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Add your API key")
      expect(user.reload.language).to eq("ruby_rails")
    end
  end

  describe "GET /setup" do
    it "offers a provider choice for each saved key only, with the one in use checked" do
      user.update!(provider: "openai", api_keys: { "anthropic" => "sk-ant-existing", "openai" => "sk-proj-kept" })
      login_as(user)

      get setup_path

      page = Nokogiri::HTML(response.body)
      choices = page.css("#provider-choice input[type=radio]")
      expect(choices.map { |input| input["value"] }).to eq(%w[anthropic openai])
      expect(page.at_css("#provider-choice input[checked]")["value"]).to eq("openai")
      expect(page.at_css("#provider-choice").text).to include("Claude", "GPT")
      expect(page.at_css("#provider-choice").text).not_to include("Gemini")
    end

    it "offers no provider choice before any key is saved" do
      login_as(user)

      get setup_path

      expect(response.body).not_to include(%(id="provider-choice"))
    end

    it "renders a weight control and an exclude toggle for every rotatable kind" do
      login_as(user)

      get setup_path

      ExerciseSection.rotatable(daily: DailyKinds::DEFAULT).each do |kind|
        expect(response.body).to include(%(id="weight-#{kind.key}"))
        expect(response.body).to include(%(id="exclude-#{kind.key}"))
        expect(response.body).to include(I18n.t("sections.#{kind.key}.name"))
      end
    end

    it "renders the stops from the constant rather than restating them" do
      login_as(user)

      get setup_path

      expect(response.body).to include(KindPreferences::MULTIPLIERS.to_json)
    end

    it "says excluding is a different action from a low weight" do
      login_as(user)

      get setup_path

      expect(response.body).to include("stronger, different action")
      expect(response.body).to include("come up less often on shorter days")
    end

    it "reflects stored preferences in the rendered controls" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 4.0 }, excluded_section_kinds: [ "parsons_problem" ])

      get setup_path

      doc = Nokogiri::HTML(response.body)

      expect(doc.at("#weight-challenge")["value"]).to eq("4")
      expect(doc.at("#exclude-parsons_problem")["checked"]).to be_present
      expect(doc.at("#weight-parsons_problem")["disabled"]).to be_present
    end
  end

  describe "cards" do
    def card_titles
      Nokogiri::HTML(response.body).css("main .phone-page > .card").map { |c| c.at_xpath("./h2 | ./div[contains(@class, 'card-heading')]/h2 | ./summary")&.text&.strip }
    end

    def first_cards
      Nokogiri::HTML(response.body).css("main .phone-page > .card").first(2)
    end

    it "opens with Connection and Your day" do
      login_as(create_user_with_key)
      get setup_path
      expect(card_titles.first(2)).to eq([ "Connection", "Your day" ])
    end

    it "orders the cards Connection, Your day, Exercise mix, Display" do
      [ create_user_with_key(email: "with-key@example.com"), user, create_trial_user ].each do |each_user|
        login_as(each_user)
        get setup_path
        expect(card_titles).to eq([ "Connection", "Your day", "Exercise mix", "Display" ])
      end
    end

    it "tags Connection with Tap Save to apply, outside its heading" do
      login_as(create_user_with_key)
      get setup_path
      heading = Nokogiri::HTML(response.body).at_css("main .phone-page > .card:first-of-type > .card-heading")
      expect(heading.at_css("h2").text.strip).to eq("Connection")
      expect(heading.at_css(".card-tag").text.strip).to eq("Tap Save to apply")
    end

    it "puts the key guide inside Connection for a user with no key and no exercises" do
      login_as(user)
      get setup_path
      expect(first_cards.first.at_css(".key-guide")).to be_present
    end

    it "keeps hint only inside the guides" do
      login_as(user)
      get setup_path
      page = Nokogiri::HTML(response.body)
      expect(page.css(".hint")).to be_present
      expect(page.css(".hint").map { |hint| hint.ancestors(".mix-note").any? }).to all(be(true))
      expect(page.css("#display-preferences .hint")).to be_empty
      expect(page.css("#exercise-mix .hint")).to be_empty
    end

    it "draws the explanations as notes without the accent border" do
      login_as(user)
      get setup_path
      page = Nokogiri::HTML(response.body)
      expect(page.css("#exercise-mix .mix-note")).to be_empty
      expect(page.css("#exercise-mix .card-note strong").map(&:text)).to eq([ I18n.t("exercise_mix.exclude_heading"), I18n.t("exercise_mix.lock_heading") ])
    end

    it "puts the trial note inside Connection while a trial runs" do
      login_as(create_trial_user)
      get setup_path
      expect(first_cards.first.text).to include(I18n.t("api_keys.edit.trial_note.title"))
    end

    it "marks the Connection and Your day notes as card notes" do
      login_as(create_user_with_key)
      get setup_path
      expect(first_cards.size).to eq(2)
      first_cards.each { |card| expect(card.css(".hint")).to be_empty }
      expect(first_cards.sum { |card| card.css(".card-note").size }).to eq(9)
    end

    it "renders each value row's current choice before any script runs, hidden from screen readers" do
      login_as(create_user_with_key(time_zone: "America/Phoenix").tap { |u| u.update!(language: "javascript", skill_level: "senior") })
      get setup_path
      rows = Nokogiri::HTML(response.body).css(".value-row")

      values = rows.map { |row| row.at_css(".value-row-value").text }
      selected = rows.map { |row| row.at_css("select option[selected]").text }
      expect(values).to eq(selected)
      expect(values).to eq([ I18n.t("api_keys.edit.language_options.javascript"), I18n.t("api_keys.edit.time_zones.arizona"),
                             I18n.t("exercise_mix.levels.senior") ])
      rows.each do |row|
        expect(row.at_css(".value-row-value")["aria-hidden"]).to eq("true")
        expect(row.at_css("label")["for"]).to eq(row.at_css("select")["id"])
      end
    end

    it "shows the detect-automatically choice in the time zone row when no zone is saved" do
      login_as(create_user_with_key(time_zone: nil))
      get setup_path
      expect(Nokogiri::HTML(response.body).at_css("#tz-select").ancestors(".value-row").first.at_css(".value-row-value").text)
        .to eq(I18n.t("api_keys.edit.time_zone_detect"))
      select = Nokogiri::HTML(response.body).at_css("#tz-select")
      expect(select.at_css("option")["value"]).to eq("")
      expect(select.at_css("option").text).to eq(I18n.t("api_keys.edit.time_zone_detect"))
      expect(select.css("option[selected]")).to be_empty
    end

    {
      "America/New_York" => "eastern", "America/Chicago" => "central", "America/Denver" => "mountain",
      "America/Phoenix" => "arizona", "America/Los_Angeles" => "pacific",
      "America/Anchorage" => "alaska", "Pacific/Honolulu" => "hawaii"
    }.each do |zone, label|
      it "keeps the existing label and single option for #{zone}" do
        login_as(create_user_with_key(time_zone: zone))
        get setup_path
        select = Nokogiri::HTML(response.body).at_css("#tz-select")
        expect(select.css("option").map { |option| option["value"] }.count(zone)).to eq(1)
        expect(select.at_css("option[selected]").text).to eq(I18n.t("api_keys.edit.time_zones.#{label}"))
        expect(select.ancestors(".value-row").first.at_css(".value-row-value").text)
          .to eq(I18n.t("api_keys.edit.time_zones.#{label}"))
      end
    end

    [ "Europe/London", "London" ].each do |zone|
      it "shows the saved unlisted zone #{zone} in the select and value row" do
        saved_user = create_user_with_key(time_zone: zone)
        login_as(saved_user)
        get setup_path
        select = Nokogiri::HTML(response.body).at_css("#tz-select")
        expect(select.css("option[selected]").map { |option| [ option["value"], option.text ] }).to eq([ [ zone, zone ] ])
        expect(select.ancestors(".value-row").first.at_css(".value-row-value").text).to eq(zone)
        expect(select.css("option").last["value"]).to eq(zone)
        expect(saved_user.reload.effective_time_zone).to eq(zone)
      end
    end

    it "shows one provider segment for one saved key and none without a key" do
      login_as(create_user_with_key(email: "one-key@example.com"))
      get setup_path
      expect(Nokogiri::HTML(response.body).css("#provider-choice .segment").size).to eq(1)

      login_as(user)
      get setup_path
      expect(Nokogiri::HTML(response.body).at_css("#provider-choice")).to be_nil
    end
  end

  describe "GET /setup exercise mix difficulty" do
    let(:user) { create_user_with_key }

    before { login_as(user) }

    it "renders difficulty controls for every section kind, fixed ones without a slider" do
      get setup_path

      ExerciseSection.all.each { |kind| expect(response.body).to include(%(data-kind="#{kind.key}")) }
      expect(response.body).to include(%(id="lock-code_review"))
      expect(response.body).not_to include(%(id="weight-code_review"))
      expect(response.body).not_to include(%(id="exclude-code_review"))
    end

    it "renders the skip control as a switch named for its kind" do
      get setup_path

      page = Nokogiri::HTML(response.body)
      box = page.at_css("#exclude-challenge")
      expect(box["role"]).to eq("switch")
      expect(box["class"].split).to include("switch", "mix-exclude-box")
      expect(box["data-action"]).to eq("change->exercise-mix#toggleExclude")
      expect(box["aria-labelledby"]).to eq("mix-name-challenge exclude-text-challenge")
      expect(page.at_css("#mix-name-challenge").text.strip).to eq(I18n.t("sections.challenge.name"))
      expect(page.at_css("#exclude-text-challenge").text.strip).to eq("Skip this kind")
    end

    it "names the skip control differently for every kind" do
      get setup_path

      page = Nokogiri::HTML(response.body)
      names = page.css(".mix-exclude-box").map do |box|
        box["aria-labelledby"].split.map { |id| page.at_css("##{id}").text.strip }.join(" ")
      end
      expect(names.size).to be > 1
      expect(names.uniq).to eq(names)
    end

    it "explains skipping in the same word as the switch" do
      get setup_path

      text = Nokogiri::HTML(response.body).at_css("#exercise-mix").text
      expect(text).to include("Skipping is a stronger, different action than turning a slider down.", "Skip means never", "Skipping also makes")
      expect(text).not_to include("Exclude")
      expect(text).not_to include("Excluding")
    end

    it "names each difficulty group and lock for its kind" do
      get setup_path

      page = Nokogiri::HTML(response.body)
      resolve = ->(node) { node["aria-labelledby"].split.map { |id| page.at_css("##{id}").text.strip }.join(" ") }
      fieldset = page.at_css("fieldset.mix-difficulty[data-kind='code_review']")
      lock = page.at_css("#lock-code_review")
      expect(fieldset["aria-labelledby"]).to eq("mix-name-code_review mix-level-legend-code_review")
      expect(page.at_css("#mix-name-code_review").text.strip).to eq(I18n.t("sections.code_review.name"))
      expect(page.at_css("#mix-level-legend-code_review").text.strip).to eq("Difficulty target")
      expect(lock["role"]).to eq("switch")
      expect(lock["class"].split).to include("switch", "mix-lock-box")
      expect(lock["aria-labelledby"]).to eq("mix-name-code_review lock-text-code_review")
      expect(resolve.call(lock)).to eq("#{I18n.t("sections.code_review.name")} Lock at this level")
      names = page.css(".mix-lock-box").map(&resolve)
      groups = page.css("fieldset.mix-difficulty").map(&resolve)
      expect(names.size).to be > 1
      expect(names.uniq).to eq(names)
      expect(groups.uniq).to eq(groups)
    end

    it "disables an excluded kind's radios and lock in the markup" do
      user.update!(excluded_section_kinds: %w[challenge])

      get setup_path

      page = Nokogiri::HTML(response.body)
      challenge = page.css('input[name="level-challenge"]') + page.css("#lock-challenge")
      expect(challenge).not_to be_empty
      expect(challenge.map { |input| input.has_attribute?("disabled") }).to all(be(true))
      expect(page.css('input[name="level-code_review"]').map { |input| input.has_attribute?("disabled") }).to all(be(false))
    end

    it "wraps each difficulty option in a row with its text in a span" do
      get setup_path

      rows = Nokogiri::HTML(response.body).css(".mix-difficulty[data-kind='challenge'] label.mix-level")
      expect(rows.size).to eq(KindDifficulty::LEVELS.size + 1)
      rows.each do |row|
        expect(row.css("input[type=radio]").size).to eq(1)
        expect(row.css("span").size).to eq(1)
      end
      expect(rows.first.at_css("span").has_attribute?("data-skill-level-label")).to be(true)
    end

    it "renders no hint in Exercise mix" do
      get setup_path

      page = Nokogiri::HTML(response.body)
      expect(page.css("#exercise-mix .mix-difficulty .hint")).to be_empty
      expect(page.css("#exercise-mix .mix-coverage").map { |note| note["class"].split }).to all(include("card-note"))
    end

    it "carries the difficulty controls' styles once, however many kinds render them" do
      get setup_path

      page = Nokogiri::HTML(response.body)
      expect(page.css("fieldset.mix-difficulty").size).to be > 1
      expect(page.css("style").count { |style| style.text.include?(".mix-difficulty {") }).to eq(1)
      expect(response.body).not_to include(".mix-difficulty.mix-suggested {")
    end

    it "adds the suggestion outline's style only when the page marks a suggested kind" do
      get setup_path(suggested: %w[code_review pattern], suggested_level: "junior")

      page = Nokogiri::HTML(response.body)
      expect(page.css("fieldset.mix-difficulty.mix-suggested").size).to eq(2)
      expect(page.css("style").count { |style| style.text.include?(".mix-difficulty.mix-suggested {") }).to eq(1)
    end

    it "hides the bulk button from a trial account" do
      login_as(create_trial_user)

      get setup_path

      expect(Nokogiri::HTML(response.body).at_css("#mix-ladder-preparation[hidden]")).to be_present
    end

    it "shows a bulk button while any section's level has gaps, targeted or not, and hides it once none do" do
      get setup_path
      expect(response.body).to include(prepare_learn_ladders_path)
      expect(Nokogiri::HTML(response.body).at_css("#mix-ladder-preparation[hidden]")).to be_nil
      expect(response.body).to include(ERB::Util.h(I18n.t("exercise_mix.ladders_explanation")))

      LadderCoverage.for(user).gaps.each do |concept, bucket|
        ConceptReference.create!(concept: concept, language: bucket, ladder_junior: "j", ladder_mid_level: "m",
                                 ladder_senior: "s", ladder_principal_engineer: "p")
      end
      get setup_path
      expect(Nokogiri::HTML(response.body).at_css("#mix-ladder-preparation[hidden]")).to be_present
    end
  end
end
