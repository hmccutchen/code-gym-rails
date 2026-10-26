require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "Concept reference alternate framings", type: :system, with_csrf: true do
  def cache_reference
    ConceptReference.create!(
      concept: "n_plus_one", language: "ruby_rails",
      tagline: "One query per row is the smell",
      explanation: "The association loads once per iteration.",
      code_example: "Post.all.each { |p| p.author.name }",
      senior_lens: "Reach for includes before the loop exists."
    )
  end

  def open_reference(user)
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i)

    box = first(".concept-alternates")
    # The nearest <details>, since the section holding it is one too; first-exposure may already have opened it.
    details = box.find(:xpath, "ancestor::details[1]")
    details.find(":scope > summary").click unless details["open"]
    box
  end

  it "adds a framing in place, then withdraws the control at the cap" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)

      box.find(".explain-concept-differently").click
      expect(box).to have_content(FakeService::CONCEPT_ALTERNATE_TEXT)

      expect(DailyResponse.count).to eq(0)
      expect(ConceptReference.find_by(concept: "n_plus_one").explanation)
        .to eq("The association loads once per iteration.")

      box.find(".explain-concept-differently").click
      expect(box).to have_css(".alternate-item", count: ConceptReferencesController::MAX_ALTERNATES_PER_CONCEPT)
      expect(box).to have_no_css(".explain-concept-differently")
    end
  end

  it "underlines glossary terms in a framing and still sends the plain text back as a prior framing" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)
      page.execute_script(<<~JS)
        window.alternateBodies = [];
        const realFetch = window.fetch;
        window.fetch = (url, options) => {
          if (String(url).includes("explain_differently")) window.alternateBodies.push(JSON.parse(options.body));
          return realFetch(url, options);
        };
      JS

      box.find(".explain-concept-differently").click
      term = box.find(".alternate-item .gloss-term", text: "eager loading")
      term.click
      expect(term[:class]).to include("gloss-open")

      box.find(".explain-concept-differently").click
      expect(box).to have_css(".alternate-item", count: ConceptReferencesController::MAX_ALTERNATES_PER_CONCEPT)
      expect(page.evaluate_script("window.alternateBodies.map((body) => body.prior_alternates)"))
        .to eq([ [], [ FakeService::CONCEPT_ALTERNATE_TEXT ] ])
    end
  end

  it "announces each framing and keeps focus in the page when the control goes" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)
      status = box.find(".alternate-status")

      box.find(".explain-concept-differently").click
      expect(status).to have_text("A different explanation was added above")
      expect(status.text).not_to include("last one")

      box.find(".explain-concept-differently").click
      expect(status).to have_text("that was the last one")
      expect(box).to have_no_css(".explain-concept-differently")

      # The focused button was removed; focus must move to the framing, not fall back to the body.
      expect(page.evaluate_script("document.activeElement.className")).to eq("alternate-item")
    end
  end

  it "refuses an OK response that isn't this endpoint's JSON, such as an expired session's login page" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)

      redirect_requests_to_login(box["data-concept-alternates-url-value"])

      box.find(".explain-concept-differently").click

      expect(box).to have_content(/session expired/i)
      expect(box).to have_no_css(".alternate-item")
      expect(box.find(".explain-concept-differently")).not_to be_disabled
    end
  end

  it "takes no space on the page while the dropdown is collapsed" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)

      details = first(".concept-alternates").find(:xpath, "ancestor::details[1]")
      details.find(":scope > summary").click if details["open"]

      expect(details).to have_no_css(".explain-concept-differently", visible: true)
    end
  end

  it "keeps nothing across a reload, which is the accepted cost of storing nothing" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)
      box.find(".explain-concept-differently").click
      expect(box).to have_content(FakeService::CONCEPT_ALTERNATE_TEXT)

      visit current_path
      expect(page).to have_content(/Code Review/i)

      expect(page).to have_no_content(FakeService::CONCEPT_ALTERNATE_TEXT)
      expect(page).to have_css(".explain-concept-differently", visible: :all)
    end
  end

  it "surfaces a server-side rejection as a status message instead of a broken page" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)

      # A real 422 from the cap guard: rspec-mocks stubs don't reach the server thread handling the driver's requests.
      page.execute_script(<<~JS)
        const realFetch = window.fetch;
        window.fetch = (url, options) => {
          const body = JSON.parse(options.body);
          body.prior_alternates = ["one", "two"];
          return realFetch(url, { ...options, body: JSON.stringify(body) });
        };
      JS

      box.find(".explain-concept-differently").click

      expect(box).to have_content(/already asked for/i)
      expect(box).to have_no_css(".alternate-item")
    end
  end
end
