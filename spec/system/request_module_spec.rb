require "rails_helper"

RSpec.describe "The shared request module", type: :system do
  let(:user) { create_fake_provider_user }

  before do
    visit_as(user)
    visit setup_path
  end

  def run(script)
    page.driver.with_playwright_page { |browser| browser.evaluate("async () => { #{script} }") }
  end

  it "sends a request on a page without a CSRF meta tag instead of throwing" do
    result = run(<<~JS)
      document.querySelectorAll('meta[name="csrf-token"]').forEach((tag) => tag.remove());
      const result = await CodeGymRequest.send("PATCH", "#{profile_path}", { user: { name: "No Tag" } });
      return result.ok;
    JS

    expect(result).to be(true)
    expect(user.reload.name).to eq("No Tag")
  end

  it "shows the app's sentence and not Rails' own error reply" do
    messages = run(<<~JS)
      const reply = (body) => () => Promise.resolve(new Response(JSON.stringify(body), { status: 422, headers: { "Content-Type": "application/json" } }));
      const original = window.fetch;
      window.fetch = reply({ status: "error", error: "The app's sentence." });
      const ours = await CodeGymRequest.send("POST", "/anything", {}, { fallback: "Fallback." });
      window.fetch = reply({ status: 500, error: "Internal Server Error" });
      const rails = await CodeGymRequest.send("POST", "/anything", {}, { fallback: "Fallback." });
      window.fetch = original;
      return [ours.message, rails.message];
    JS

    expect(messages).to eq([ "The app's sentence.", "Fallback." ])
  end

  it "sends a key's queued saves one at a time, in order, and counts the waiting ones as pending" do
    result = run(<<~JS)
      const original = window.fetch;
      const sent = [];
      let release;
      window.fetch = (url, options) => {
        sent.push(JSON.parse(options.body).user.name);
        if (sent.length === 1) return new Promise((resolve) => { release = () => resolve(original(url, options)); });
        return original(url, options);
      };
      const first = CodeGymSaveStatus.queue("name", "PATCH", "#{profile_path}", { user: { name: "First" } });
      const second = CodeGymSaveStatus.queue("name", "PATCH", "#{profile_path}", { user: { name: "Second" } });
      await new Promise((resolve) => setTimeout(resolve, 50));
      const whileHeld = { sent: sent.slice(), pending: CodeGymSaveStatus.pending(), queued: CodeGymSaveStatus.queued("name") };
      release();
      await Promise.all([first, second]);
      await new Promise((resolve) => setTimeout(resolve, 50));
      window.fetch = original;
      return { whileHeld: whileHeld, sent: sent, pending: CodeGymSaveStatus.pending() };
    JS

    expect(result["whileHeld"]).to eq("sent" => [ "First" ], "pending" => true, "queued" => true)
    expect(result["sent"]).to eq(%w[First Second])
    expect(result["pending"]).to be(false)
    expect(user.reload.name).to eq("Second")
  end
end
