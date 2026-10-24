require "rails_helper"

RSpec.describe "The shared fetch stub", type: :system do
  let(:user) { create_fake_provider_user }

  before do
    visit_as(user)
    visit setup_path
    wait_for_js
  end

  def send_request(method, url, body = nil)
    page.driver.with_playwright_page do |browser|
      browser.evaluate(<<~JS)
        async () => {
          const result = await CodeGymRequest.send(#{method.to_json}, #{url.to_json}, #{body.to_json}, { fallback: "Fallback." });
          return { ok: result.ok, status: result.status, message: result.message, signedOut: result.signedOut };
        }
      JS
    end
  end

  def rename(name, url: profile_path) = send_request("PATCH", url, { user: { name: name } })

  it "answers a request to the stubbed path with the reply and leaves the server untouched" do
    fail_requests_to(profile_path)

    expect(rename("Stubbed")).to eq("ok" => false, "status" => 500, "message" => "nope", "signedOut" => false)
    expect(user.reload.name).not_to eq("Stubbed")
  end

  it "matches the path of an absolute URL and of a URL with a query string" do
    fail_requests_to(profile_path)
    absolute = page.evaluate_script("location.origin") + profile_path

    expect(rename("Absolute", url: absolute)["status"]).to eq(500)
    expect(rename("Queried", url: "#{profile_path}?from=spec")["status"]).to eq(500)
    expect(user.reload.name).not_to be_in(%w[Absolute Queried])
  end

  it "passes a request to any other path to the real fetch" do
    fail_requests_to(level_suggestion_answer_path)

    expect(rename("Passed through")).to include("ok" => true, "status" => 200)
    expect(user.reload.name).to eq("Passed through")
  end

  it "passes through a path that only shares the stubbed path's beginning, unless asked to match a prefix" do
    stub_fetch("/prof", FetchStubHelper::SERVER_ERROR_REPLY)
    expect(rename("Longer path")).to include("ok" => true)

    stub_fetch("/daily_kinds/", %(Promise.resolve(new Response("", { status: 503 }))), prefix: true)
    expect(send_request("PATCH", daily_kind_path(0), {})["status"]).to eq(503)
    expect(send_request("PATCH", daily_kind_path(1), {})["status"]).to eq(503)
    expect(user.reload.name).to eq("Longer path")
  end

  it "takes a reply written as a statement, with its closing semicolon" do
    stub_fetch(profile_path, "#{FetchStubHelper::SERVER_ERROR_REPLY};\n")

    expect(rename("Semicolon")["status"]).to eq(500)
  end

  it "keeps an earlier stub in place when another path is stubbed after it" do
    fail_requests_to(level_suggestion_answer_path)
    drop_requests_to(profile_path)

    expect(send_request("POST", level_suggestion_answer_path, {})["status"]).to eq(500)
    expect(rename("Dropped")).to include("ok" => false, "status" => 0, "message" => "Fallback.")
  end

  it "rejects a dropped request the way a lost connection does" do
    drop_requests_to(profile_path)

    expect(rename("Offline")).to eq("ok" => false, "status" => 0, "message" => "Fallback.", "signedOut" => false)
    expect(user.reload.name).not_to eq("Offline")
  end

  it "answers a signed-out request the way an expired session does" do
    redirect_requests_to_login(profile_path)

    expect(rename("Signed out")).to include("ok" => false, "signedOut" => true, "message" => I18n.t("request.signed_out"))
    expect(user.reload.name).not_to eq("Signed out")
  end

  it "breaks every request when the whole network is down" do
    break_the_network

    expect(rename("No network")).to include("status" => 0, "message" => "Fallback.")
    expect(send_request("GET", dashboard_status_path)).to include("status" => 0)
  end
end
