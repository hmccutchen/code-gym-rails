require "rails_helper"

RSpec.describe "Daily featured concept", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  # Escaped the way the page renders it, derived from the same string the view
  # reads — the label carries an apostrophe, so a raw comparison silently never
  # matches and every "renders no callout" example would pass vacuously.
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

    # The point of picking on visit rather than on a schedule: a weekend
    # dashboard has no set on it and is exactly where this has something to
    # offer.
    it "surfaces it on a weekend, when the page has no set to show" do
      write_up("idempotency_at_scale")

      # Midday Saturday in the team's own zone, not a bare Date: the pick
      # resolves its day there, so a date pinned in some other zone could land
      # on the Friday and quietly stop testing a weekend at all.
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

  # A user assigned one language must never be pointed at the other's
  # vocabulary: LearnController#show would 404 on the link.
  it "never features a concept outside a single-language user's own slice" do
    user.update!(language: "ruby_rails")
    write_up("prototype_chain", language: "javascript")
    get learn_path

    expect(response.body).not_to include(featured_label)
  end

  # The featured row is picked for staleness, not for having a guide, so a
  # backfill that stopped short can put an un-guided concept in the slot.
  # Nothing new catches that — its own page already offers to write it.
  it "sends a concept with no guide to the page that offers to write one" do
    write_up("idempotency_at_scale")
    get learn_path

    get learn_concept_path(bucket: "architecture", concept: "idempotency_at_scale")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Write this up")
  end
end
