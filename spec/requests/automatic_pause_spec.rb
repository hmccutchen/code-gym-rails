require "rails_helper"

RSpec.describe "The automatic pause on the dashboard and the Account page", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key }
  let(:paused_at) { Time.utc(2026, 7, 9, 8) }
  let(:monday_noon) { Time.utc(2026, 7, 13, 12) }
  let(:saturday_noon) { Time.utc(2026, 7, 18, 12) }
  let(:line) { I18n.t("dashboard.automatic_pause.message") }

  def pause(source)
    user.update_columns(paused_generation_at: paused_at, generation_pause_source: source)
  end

  def dashboard_at(moment)
    travel_to(moment) do
      login_as(user)
      get root_path
    end
    Nokogiri::HTML(response.body)
  end

  def pause_columns = user.reload.slice(:paused_generation_at, :generation_pause_source).symbolize_keys

  def posted_fields(form) = form.css("input[type=hidden]").to_h { |input| [ input["name"], input["value"] ] }

  describe "the dashboard line" do
    it "says why generation paused, in the words the pause rule's count allows" do
      expect(line).to eq("Generation paused after three sets in a row went unopened, so your key isn't spent on sets you don't see.")
      expect(line).to include({ 3 => "three" }.fetch(UnopenedSets::PAUSE_AFTER))
    end

    it "shows for an automatic pause, above the page's state and outside what the generating poll replaces" do
      pause("automatic")

      page = dashboard_at(monday_noon)

      expect(page.at_css(".automatic-pause").text).to include(line)
      expect(page.at_css("#dashboard-content .automatic-pause")).to be_nil
      expect(response.body.index(ERB::Util.h(line))).to be < response.body.index('id="dashboard-content"')
      expect(response.body).to include("Automatic generation is paused")
    end

    it "does not show for a manual pause, a pause with no source, or a running account" do
      [ "manual", nil ].each do |source|
        pause(source)

        expect(dashboard_at(monday_noon).at_css(".automatic-pause")).to be_nil
      end
      user.update_columns(paused_generation_at: nil, generation_pause_source: "automatic")

      expect(dashboard_at(monday_noon).at_css(".automatic-pause")).to be_nil
    end

    it "shows on a weekend, above the weekend message" do
      pause("automatic")

      page = dashboard_at(saturday_noon)

      expect(page.at_css(".automatic-pause").text).to include(line)
      expect(response.body).to include("No exercises are generated automatically on weekends")
    end

    it "shows when a set is on the page" do
      pause("automatic")
      travel_to(monday_noon) do
        DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                              problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } })
      end

      page = dashboard_at(monday_noon)

      expect(page.at_css(".automatic-pause").text).to include(line)
      expect(response.body).to include('data-rating-for="code_review"')
    end

    it "sits in the page's card as a notice, with Resume as the primary button and Keep it paused the quiet one, both full size" do
      pause("automatic")

      notice = dashboard_at(monday_noon).at_css(".automatic-pause")

      expect(notice["class"].split).to include("section")
      expect(notice["role"]).to eq("status")
      expect(notice.css("button").map { |button| button["class"].split }).to eq([ %w[btn btn-primary], %w[btn btn-ghost] ])
    end

    it "leaves the paused card beneath it without its own resume link, so the page has one way to resume" do
      pause("automatic")

      page = dashboard_at(monday_noon)

      expect(page.css("a[href='#{account_path}']").map(&:text)).not_to include(I18n.t("dashboard.paused_empty.resume"))
      expect(page.at_css("#dashboard-content").text).to include("Automatic generation is paused", "Generate today's set anyway")
      expect(page.css(".automatic-pause form button").map { |button| button.text.strip }).to include("Resume")
    end

    it "keeps the paused card's resume link for a manual pause, whose page is unchanged" do
      pause("manual")

      page = dashboard_at(monday_noon)

      expect(page.at_css("#dashboard-content .today-state-link a[href='#{account_path}']").text)
        .to eq(I18n.t("dashboard.paused_empty.resume"))
      expect(page.at_css(".automatic-pause")).to be_nil
    end

    it "offers Resume and Keep it paused as plain forms that post the state they want and name the dashboard" do
      pause("automatic")

      forms = dashboard_at(monday_noon).css(".automatic-pause form")

      expect(forms.map { |form| form.at_css("button").text.strip }).to eq([ "Resume", "Keep it paused" ])
      expect(forms.map { |form| form["action"] }.uniq).to eq([ toggle_generation_account_path ])
      expect(forms.map { |form| posted_fields(form).slice("_method", "paused", "return_to") }).to eq([
        { "_method" => "patch", "paused" => "0", "return_to" => "dashboard" },
        { "_method" => "patch", "paused" => "1", "return_to" => "dashboard" }
      ])
      expect(forms.css("[data-controller], [data-action]")).to be_empty
    end
  end

  describe "Resume from the line" do
    it "clears both columns in one tap, lands on the dashboard and starts today's set" do
      pause("automatic")
      travel_to(monday_noon) do
        login_as(user)

        patch toggle_generation_account_path, params: { paused: "0", return_to: "dashboard" }

        expect(response).to redirect_to(root_path)
        expect(pause_columns).to eq(paused_generation_at: nil, generation_pause_source: nil)
        expect { follow_redirect! }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)
      end
      expect(response.body).to include("Automatic daily generation resumed.", "Generating your personalized exercise set")
      expect(response.body).not_to include(line)
    end

    it "carries none of the unopened sets forward" do
      pause("automatic")
      unopened = [ 6, 7, 8 ].map do |day|
        DailyExercise.create!(user: user, date: Date.new(2026, 7, day), generated_at: Time.utc(2026, 7, day, 8),
                              problem_set: { "code_review" => { "question" => "q" } })
      end
      travel_to(monday_noon) do
        login_as(user)

        patch toggle_generation_account_path, params: { paused: "0", return_to: "dashboard" }
        follow_redirect!
      end

      expect(response.body).not_to include("The set you had waiting")
      expect(unopened.map { |set| set.reload.date.day }).to eq([ 6, 7, 8 ])
    end
  end

  describe "Keep it paused" do
    it "changes the source to manual, leaves the pause time alone and lands on a dashboard without the line" do
      pause("automatic")
      travel_to(monday_noon) do
        login_as(user)

        patch toggle_generation_account_path, params: { paused: "1", return_to: "dashboard" }

        expect(response).to redirect_to(root_path)
        expect(pause_columns).to eq(paused_generation_at: paused_at, generation_pause_source: "manual")
        expect { follow_redirect! }.not_to have_enqueued_job(GenerateDailyExercisesJob)
      end
      expect(response.body).to include("Automatic generation stays paused.")
      expect(response.body).not_to include(line)
    end
  end

  describe "where the action sends the browser afterwards" do
    before { pause("automatic") }

    it "returns to the Account page when no return is named" do
      login_as(user)

      patch toggle_generation_account_path, params: { paused: "0" }

      expect(response).to redirect_to(account_path)
    end

    [ "https://evil.example/", "//evil.example", "/history", "dashboard/../../evil", "DASHBOARD", "" ].each do |value|
      it "ignores return_to=#{value.inspect} on Resume and Keep it paused, and stays on this site's Account page" do
        login_as(user)

        [ "1", "0" ].each do |state|
          patch toggle_generation_account_path, params: { paused: state, return_to: value }

          expect(response).to redirect_to(account_path)
          expect(URI(response.location).host).to eq(request.host)
        end
      end
    end

    it "ignores a return_to sent as a list or a map" do
      login_as(user)

      patch toggle_generation_account_path, params: { paused: "1", return_to: [ "dashboard" ] }
      expect(response).to redirect_to(account_path)

      patch toggle_generation_account_path, params: { paused: "1", return_to: { url: "https://evil.example/" } }
      expect(response).to redirect_to(account_path)
    end
  end

  describe "the Account page" do
    it "records its Pause button as a manual pause" do
      travel_to(monday_noon) do
        login_as(user)

        patch toggle_generation_account_path, params: { paused: "1" }
        follow_redirect!
      end

      expect(pause_columns).to eq(paused_generation_at: monday_noon, generation_pause_source: "manual")
      expect(response.body).to include("Automatic daily generation paused.")
    end

    it "says a manual pause is one the user made" do
      pause("manual")
      login_as(user)

      get account_path

      expect(response.body).to include("Automatic generation is paused (since July 9).")
      expect(response.body).not_to include("went unopened")
    end

    it "says an automatic pause came from unopened sets, and keeps the same Resume button" do
      pause("automatic")
      login_as(user)

      get account_path

      expect(response.body).to include("Automatic generation paused on July 9, after three sets in a row went unopened.")
      expect(response.body).to include("Resume automatic generation")
      expect(I18n.t("accounts.show.paused_automatically", date: "July 9")).to include({ 3 => "three" }.fetch(UnopenedSets::PAUSE_AFTER))
    end

    it "reads a pause with no source as manual" do
      pause(nil)
      login_as(user)

      get account_path

      expect(response.body).to include("Automatic generation is paused (since July 9).")
    end
  end
end
