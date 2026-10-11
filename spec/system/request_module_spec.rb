require "rails_helper"

RSpec.describe "The shared request module", type: :system do
  let(:user) { create_fake_provider_user }

  before do
    visit_as(user)
    visit setup_path
    wait_for_js
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

  it "keeps the newest name when the nav editor's saves overlap, without using the save banner" do
    result = run(<<~JS)
      const original = window.fetch;
      const sent = [];
      let release;
      window.fetch = (url, options) => {
        if (!String(url).includes("/profile")) return original(url, options);
        sent.push(JSON.parse(options.body).user.name);
        if (sent.length === 1) return new Promise((resolve) => { release = () => resolve(original(url, options)); });
        return original(url, options);
      };
      const input = document.getElementById("nav-name-input");
      input.value = "Older";
      input.dispatchEvent(new Event("blur"));
      input.value = "Newer";
      input.dispatchEvent(new Event("blur"));
      await new Promise((resolve) => setTimeout(resolve, 50));
      const whileHeld = sent.slice();
      release();
      while (CodeGymSaveStatus.pending()) await new Promise((resolve) => setTimeout(resolve, 20));
      window.fetch = original;
      return { whileHeld: whileHeld, sent: sent, shown: input.value, banner: document.getElementById("save-status").hidden };
    JS

    expect(result["whileHeld"]).to eq([ "Older" ])
    expect(result["sent"]).to eq(%w[Older Newer])
    expect(result["shown"]).to eq("Newer")
    expect(user.reload.name).to eq("Newer")
    expect(result["banner"]).to be(true)
  end

  it "keeps a quiet save's failure out of the banner" do
    hidden = run(<<~JS)
      const original = window.fetch;
      window.fetch = () => Promise.resolve(new Response(JSON.stringify({ status: "error", error: "Refused." }), { status: 422 }));
      await CodeGymSaveStatus.queue("time_zone", "PATCH", "#{profile_path}", { user: { time_zone: "UTC" } }, { quiet: true });
      window.fetch = original;
      return document.getElementById("save-status").hidden;
    JS

    expect(hidden).to be(true)
  end

  it "keeps the earlier saved name in the field when a newer name's save fails" do
    result = run(<<~JS)
      const original = window.fetch;
      let calls = 0;
      let release;
      window.fetch = (url, options) => {
        if (!String(url).includes("/profile")) return original(url, options);
        calls += 1;
        if (calls === 1) return new Promise((resolve) => { release = () => resolve(original(url, options)); });
        return Promise.resolve(new Response(JSON.stringify({ status: "error", error: "Refused." }), { status: 422 }));
      };
      const input = document.getElementById("nav-name-input");
      input.value = "Saved First";
      input.dispatchEvent(new Event("blur"));
      input.value = "Refused Second";
      input.dispatchEvent(new Event("blur"));
      await new Promise((resolve) => setTimeout(resolve, 50));
      release();
      while (CodeGymSaveStatus.pending()) await new Promise((resolve) => setTimeout(resolve, 20));
      window.fetch = original;
      return input.value;
    JS

    expect(result).to eq("Saved First")
    expect(user.reload.name).to eq("Saved First")
  end

  it "drops a save whose body throws and still sends the next one" do
    result = run(<<~JS)
      const dropped = await CodeGymSaveStatus.queue("broken", "PATCH", "#{profile_path}", () => { throw new Error("boom"); });
      const next = await CodeGymSaveStatus.queue("broken", "PATCH", "#{profile_path}", { user: { name: "After Throw" } });
      while (CodeGymSaveStatus.pending()) await new Promise((resolve) => setTimeout(resolve, 20));
      return { dropped: dropped.skipped === true, next: next.ok, pending: CodeGymSaveStatus.pending() };
    JS

    expect(result).to eq("dropped" => true, "next" => true, "pending" => false)
    expect(user.reload.name).to eq("After Throw")
  end
end
