require "rails_helper"

RSpec.describe "The nav name editor", type: :system do
  let(:user) { create_fake_provider_user(name: "Original") }

  def run(script)
    page.driver.with_playwright_page { |pw| pw.evaluate("(async () => { #{script} })()") }
  end

  it "keeps text typed while a save is in flight" do
    visit_as(user)
    expect(page).to have_css("#nav-name-input", visible: :all)
    wait_for_js

    result = run(<<~JS)
      const original = window.fetch;
      let release;
      window.fetch = (url, options) => {
        if (!String(url).includes("/profile")) return original(url, options);
        window.fetch = original;
        return new Promise((resolve) => { release = () => resolve(original(url, options)); });
      };
      const input = document.getElementById("nav-name-input");
      input.value = "Alice";
      input.dispatchEvent(new Event("blur"));
      await new Promise((resolve) => setTimeout(resolve, 50));
      input.value = "Alice Smith";
      release();
      while (CodeGymSaveStatus.pending()) await new Promise((resolve) => setTimeout(resolve, 20));
      await new Promise((resolve) => setTimeout(resolve, 50));
      return input.value;
    JS

    expect(result).to eq("Alice Smith")
    expect(user.reload.name).to eq("Alice")
  end
end
