require "rails_helper"

# The control is inline JavaScript talking to a JSON endpoint, so request specs
# execute none of it. These cover the parts that only exist in the browser: the
# fetch round trip, the cap shared across every copy of one reference on the
# page, and the fact that nothing survives a reload.
RSpec.describe "Concept reference alternate framings", type: :system, with_csrf: true do
  # The inline script reads the CSRF meta tag before every fetch, and
  # allow_forgery_protection off (config/environments/test.rb) blanks it.
  # See spec/support/csrf_helper.rb.

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
    perform_enqueued_jobs { visit_as(user) }
    expect(page).to have_content(/Code Review/i, wait: 10)

    box = first(".concept-alternates")
    # The first-exposure auto-expand may already have opened this one; only
    # click the summary when it hasn't.
    details = box.find(:xpath, "ancestor::details")
    details.find("summary").click unless details["open"]
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

  # Both of these are what the live region and the focus move exist for, and
  # neither is observable outside a browser.
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

      # The button holding focus was just removed; focus must have moved to the
      # framing rather than falling back to the body.
      expect(page.evaluate_script("document.activeElement.className")).to eq("alternate-item")
    end
  end

  # An expired session redirects to the HTML login form, and fetch follows that
  # transparently — 200, res.ok true, body a page. Parsing has to fail closed:
  # an earlier version fell back to {} and appended an undefined framing.
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
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      details = first(".concept-alternates").find(:xpath, "ancestor::details")
      details.find("summary").click if details["open"]

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

      # A real 422 from the endpoint, rather than a stubbed provider: rspec-mocks
      # stubs set here don't reach the server thread the driver's requests are
      # handled on. Overstating the framings already shown trips the cap guard.
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
