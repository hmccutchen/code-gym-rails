require "rails_helper"

RSpec.describe "Concept reference alternate framings", type: :request do
  let(:user) { create_user_with_key }
  let(:reference) do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")
  end

  def stub_alternate(text = "A different angle")
    fake = instance_double(ClaudeService)
    allow(AiService).to receive(:for).and_return(fake)
    allow(fake).to receive(:explain_concept_differently).and_return(text)
    fake
  end

  def post_alternate(prior: [])
    post explain_differently_concept_reference_path(reference),
         params: { prior_alternates: prior }, as: :json
  end

  it "returns a framing and how many remain" do
    stub_alternate("Picture a library courier.")
    login_as(user)

    post_alternate

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(
      "status" => "ok", "alternate" => "Picture a library courier.", "remaining" => 1
    )
  end

  # The whole point of this surface: it is reachable while someone is still
  # working, before any DailyResponse row exists at all.
  it "works with no response — and no exercise — of any kind" do
    stub_alternate
    login_as(user)

    post_alternate

    expect(response).to have_http_status(:ok)
    expect(DailyResponse.count).to eq(0)
  end

  it "writes nothing anywhere, leaving the shared reference untouched" do
    stub_alternate
    login_as(user)

    expect { post_alternate }.not_to change { reference.reload.attributes }
  end

  it "passes the framings already shown to the provider" do
    fake = stub_alternate
    login_as(user)

    post_alternate(prior: [ "A restaurant-orders analogy" ])

    expect(fake).to have_received(:explain_concept_differently).with(
      user, reference, prior_alternates: [ "A restaurant-orders analogy" ]
    )
  end

  it "returns 422 at the cap and does not call the provider" do
    fake = stub_alternate
    login_as(user)

    post_alternate(prior: [ "one", "two" ])

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)).to eq(
      "status" => "error",
      "error" => "You've already asked for 2 other framings of this concept."
    )
    expect(fake).not_to have_received(:explain_concept_differently)
  end

  it "rejects a prior list too large to forward" do
    fake = stub_alternate
    login_as(user)

    post_alternate(prior: [ "x" * (ConceptReferencesController::MAX_PRIOR_ALTERNATE_BYTES + 1) ])

    expect(response).to have_http_status(:unprocessable_content)
    expect(fake).not_to have_received(:explain_concept_differently)
  end

  it "ignores non-string entries rather than raising on them" do
    fake = stub_alternate
    login_as(user)

    post explain_differently_concept_reference_path(reference),
         params: { prior_alternates: [ { "role" => "user" }, "a real framing" ] }, as: :json

    expect(response).to have_http_status(:ok)
    expect(fake).to have_received(:explain_concept_differently).with(
      user, reference, prior_alternates: [ "a real framing" ]
    )
  end

  it "treats a non-array prior list as no prior framings rather than raising" do
    fake = stub_alternate
    login_as(user)

    post explain_differently_concept_reference_path(reference),
         params: { prior_alternates: { "0" => "not an array" } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(fake).to have_received(:explain_concept_differently).with(
      user, reference, prior_alternates: []
    )
  end

  it "answers an unknown reference in JSON, not an HTML 404" do
    stub_alternate
    login_as(user)

    post explain_differently_concept_reference_path(id: reference.id + 1), as: :json

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["status"]).to eq("error")
  end

  it "surfaces a provider failure as a 503" do
    fake = instance_double(ClaudeService)
    allow(AiService).to receive(:for).and_return(fake)
    allow(fake).to receive(:explain_concept_differently)
      .and_raise(AiService::RateLimitError, "slow down")
    login_as(user)

    post_alternate

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)).to eq("status" => "error", "error" => "slow down")
  end

  it "requires a login" do
    post_alternate

    expect(response).to redirect_to(login_path)
  end
end
