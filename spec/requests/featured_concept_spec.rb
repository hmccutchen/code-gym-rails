require "rails_helper"

RSpec.describe "Weekly featured concept", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  # The label carries an apostrophe, so a raw comparison would never match and pass vacuously.
  def featured_label
    ERB::Util.html_escape(I18n.t("learn.featured.label")).to_s
  end

  def write_up(concept, language: "architecture", **fields)
    ConceptReference.create!(
      concept: concept, language: language,
      tagline: "Do the boring thing", explanation: "e", code_example: "c", senior_lens: "s",
      **fields
    )
  end

  context "on the Learn tab" do
    it "surfaces one concept above the list" do
      write_up("idempotency_at_scale")
      get learn_path

      expect(response.body).to include(featured_label)
      expect(response.body).to include("Do the boring thing")
    end

    it "links it to its own Learn page" do
      write_up("idempotency_at_scale")
      get learn_path

      expect(response.body).to include(
        learn_concept_path(bucket: "architecture", concept: "idempotency_at_scale")
      )
    end

    it "renders no callout before anything has been written up" do
      get learn_path

      expect(response.body).not_to include(featured_label)
    end
  end

  context "on the dashboard" do
    it "surfaces the same concept as a callout" do
      write_up("idempotency_at_scale")
      get root_path

      expect(response.body).to include(featured_label)
      expect(response.body).to include(
        learn_concept_path(bucket: "architecture", concept: "idempotency_at_scale")
      )
    end

    it "surfaces it on a weekend, when the page has no set to show" do
      write_up("idempotency_at_scale")

      # Midday Saturday in the team's zone, so the pick cannot resolve to Friday.
      travel_to Time.utc(2026, 9, 12, 16, 0, 0) do
        expect(ConceptReference.team_today).to be_on_weekend

        get root_path

        expect(response.body).to include(featured_label)
      end
    end

    it "renders no callout before anything has been written up" do
      get root_path

      expect(response.body).not_to include(featured_label)
    end
  end

  it "shows every user the same concept" do
    write_up("idempotency_at_scale")
    write_up("caching_strategy")
    get learn_path
    mine = response.body[/learn\/architecture\/(\w+)/, 1]

    login_as(create_user_with_key(email: "other@example.com", name: "Other"))
    get root_path

    expect(response.body).to include(learn_concept_path(bucket: "architecture", concept: mine))
  end

  # LearnController#show would 404 on a concept outside the user's language.
  it "never features a concept outside a single-language user's own slice" do
    user.update!(language: "ruby_rails")
    write_up("prototype_chain", language: "javascript")
    get learn_path

    expect(response.body).not_to include(featured_label)
  end

  # The pick ignores whether a guide exists, so a concept without one can be featured.
  it "sends a concept with no guide to the page that offers to write one" do
    write_up("idempotency_at_scale")
    get learn_path

    get learn_concept_path(bucket: "architecture", concept: "idempotency_at_scale")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Write this up")
  end
end
