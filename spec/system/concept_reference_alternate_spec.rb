require "rails_helper"

# The control is inline JavaScript, so request specs execute none of it.
RSpec.describe "Concept reference alternate framings", type: :system, with_csrf: true do
  # with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).

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
    expect(page).to have_content(/Code Review/i, wait: 10)

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
      expect(box).to have_content(FakeService::CONCEPT_ALTERNATE_TEXT, wait: 10)

      # Nothing is written anywhere — not a response, and not the shared row.
      expect(DailyResponse.count).to eq(0)
      expect(ConceptReference.find_by(concept: "n_plus_one").explanation)
        .to eq("The association loads once per iteration.")

      box.find(".explain-concept-differently").click
      expect(box).to have_css(".alternate-item", count: ConceptReferencesController::MAX_ALTERNATES_PER_CONCEPT, wait: 10)
      expect(box).to have_no_css(".explain-concept-differently")
    end
  end

  it "announces each framing and keeps focus in the page when the control goes" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)
      status = box.find(".alternate-status")

      box.find(".explain-concept-differently").click
      expect(status).to have_text("A different explanation was added above", wait: 10)
      expect(status.text).not_to include("last one")

      box.find(".explain-concept-differently").click
      expect(status).to have_text("that was the last one", wait: 10)
      expect(box).to have_no_css(".explain-concept-differently")

      # The focused button was removed; focus must move to the framing, not fall back to the body.
      expect(page.evaluate_script("document.activeElement.className")).to eq("alternate-item")
    end
  end

  # An expired session's login page arrives as a 200; parsing must fail closed rather than append an undefined framing.
  it "refuses an OK response that isn't the JSON this endpoint returns" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      box = open_reference(user)

      page.execute_script(<<~JS)
        window.fetch = () => Promise.resolve(Object.defineProperty(
          new Response("<html><body>Please log in first.</body></html>",
                       { status: 200, headers: { "Content-Type": "text/html" } }),
          "redirected", { value: true }
        ));
      JS

      box.find(".explain-concept-differently").click

      expect(box).to have_content(/session expired/i, wait: 10)
      expect(box).to have_no_css(".alternate-item")
      # Recoverable, and the control is still there to recover with.
      expect(box.find(".explain-concept-differently")).not_to be_disabled
    end
  end

  it "takes no space on the page while the dropdown is collapsed" do
    user = create_fake_provider_user
    cache_reference

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

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
      expect(box).to have_content(FakeService::CONCEPT_ALTERNATE_TEXT, wait: 10)

      visit current_path
      expect(page).to have_content(/Code Review/i, wait: 10)

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

      expect(box).to have_content(/already asked for/i, wait: 10)
      expect(box).to have_no_css(".alternate-item")
    end
  end
end
