require "rails_helper"

RSpec.describe "Track select on Setup", type: :system do
  let(:user) { create_fake_provider_user }

  def default_labels
    all("[data-skill-level-label]", visible: :all).map { |label| label.text(:all) }.uniq
  end

  before do
    visit_as(user)
    visit setup_path
  end

  it "previews without saving, then applies and renames the Exercise mix default options" do
    select "Senior", from: "Track", visible: :all

    expect(page).to have_button("Apply track", disabled: false)
    expect(default_labels).to eq([ "Your track (Junior)" ])
    expect(user.reload.skill_level).to eq("junior")
    click_button "Apply track"

    expect(page).to have_css("[data-skill-level-label]", text: "Your track (Senior)", visible: :all)
    expect(default_labels).to eq([ "Your track (Senior)" ])
    expect(user.reload.skill_level).to eq("senior")
    expect(page).to have_current_path(setup_path)
  end

  it "holds a second change until the first save lands, then stores it" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/profile") && JSON.parse(options.body).user.skill_level === "senior") {
          return new Promise((resolve) => { window.releaseSenior = () => resolve(originalFetch(url, options)); });
        }
        return originalFetch(url, options);
      };
    JS

    select "Senior", from: "Track", visible: :all
    click_button "Apply track"
    wait_for_js_condition("typeof window.releaseSenior === 'function'")
    expect(page).to have_css("#skill-level[disabled]", visible: :all)
    page.execute_script("window.releaseSenior()")
    expect(page).to have_css("#skill-level:not([disabled])", visible: :all)
    select "Principal engineer", from: "Track", visible: :all
    click_button "Apply track"
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

    expect(user.reload.skill_level).to eq("principal_engineer")
    expect(default_labels).to eq([ "Your track (Principal engineer)" ])
  end

  it "reports a failed preview and keeps Apply disabled and the labels naming the stored level" do
    break_the_network

    select "Principal engineer", from: "Track", visible: :all

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(default_labels).to eq([ "Your track (Junior)" ])
    expect(user.reload.skill_level).to eq("junior")
    expect(page).to have_button("Apply track", disabled: true)
  end

  it "shows a malformed successful preview response as a failure, never an enabled Apply" do
    stub_fetch(profile_track_preview_path, 'Promise.resolve(new Response("not JSON", { status: 200 }))')

    select "Senior", from: "Track", visible: :all

    expect(page).to have_css("#save-status", text: I18n.t("tracks.preview.unconfirmed"))
    expect(page).to have_button("Apply track", disabled: true)
    expect(page).to have_button("Refresh preview", disabled: false)
    expect(user.reload.skill_level).to eq("junior")
  end

  it "shows an incomplete successful Apply response as unconfirmed and permits recovery" do
    select "Senior", from: "Track", visible: :all
    expect(page).to have_button("Apply track", disabled: false)
    stub_fetch(profile_path, 'Promise.resolve(new Response("{}", { status: 200 }))')

    click_button "Apply track"

    expect(page).to have_css("#save-status", text: I18n.t("tracks.preview.unconfirmed"))
    expect(page).to have_button("Refresh preview", disabled: false)
    expect(default_labels).to eq([ "Your track (Junior)" ])
    expect(user.reload.skill_level).to eq("junior")
  end

  def shown_track
    find("#skill-level", visible: :all).ancestor(".value-row").find(".value-row-value", visible: :all).text(:all)
  end

  it "updates the Track row's shown value" do
    select "Senior", from: "Track", visible: :all

    expect(page).to have_css(".value-row-value", text: "Senior")
    expect(shown_track).to eq("Senior")
  end

  it "keeps the Track row's shown value matching its select after a failed save" do
    fail_requests_to(profile_path)

    select "Principal engineer", from: "Track", visible: :all
    click_button "Apply track"

    expect(page).to have_css("#save-status", text: "nope")
    expect(page).to have_css("#skill-level:not([disabled])", visible: :all)
    expect(shown_track).to eq(page.evaluate_script("document.getElementById('skill-level').selectedOptions[0].text"))
    expect(shown_track).to eq("Principal engineer")
  end

  it "cancels the proposal and restores only the saved track select and value row" do
    select "Senior", from: "Track", visible: :all
    expect(page).to have_button("Apply track", disabled: false)
    click_button "Cancel track change"

    expect(page).to have_no_button("Apply track")
    expect(find("#skill-level", visible: :all).value).to eq("junior")
    expect(shown_track).to eq("Junior")
    expect(user.reload.skill_level).to eq("junior")
  end

  it "ignores an older preview reply after a newer selection or Cancel" do
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/profile/track_preview") && JSON.parse(options.body).user.skill_level === "senior") {
          return send(url, options).then(reply => new Promise(resolve => {
            window.releasePreview = () => resolve(reply);
          }));
        }
        return send(url, options);
      };
    JS
    select "Senior", from: "Track", visible: :all
    wait_for_js_condition("typeof window.releasePreview === 'function'")
    select "Mid-level", from: "Track", visible: :all
    page.execute_script("window.releasePreview()")
    expect(page).to have_button("Apply track", disabled: false)
    expect(find('[data-profile-preferences-target="preview"]').text).to include("Mid-level")
    expect(find('[data-profile-preferences-target="preview"]').text).not_to include("Senior")
    expect(user.reload.skill_level).to eq("junior")
    page.execute_script("window.releasePreview = undefined")
    select "Senior", from: "Track", visible: :all
    wait_for_js_condition("typeof window.releasePreview === 'function'")
    click_button "Cancel track change"
    page.execute_script("window.releasePreview()")
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
    expect(page).to have_no_button("Apply track")
    expect(user.reload.skill_level).to eq("junior")
  end

  it "recovers a lost successful Apply reply through an already-saved preview without a second write" do
    page.execute_script(<<~JS)
      const send = window.fetch;
      window.trackWrites = 0;
      window.fetch = (url, options) => {
        if (url.endsWith("/profile") && JSON.parse(options.body).user.skill_level) {
          window.trackWrites++;
          return send(url, options).then(() => Promise.reject(new TypeError("reply lost")));
        }
        return send(url, options);
      };
    JS
    select "Senior", from: "Track", visible: :all
    click_button "Apply track"
    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(user.reload.skill_level).to eq("senior")
    expect(default_labels).to eq([ "Your track (Junior)" ])
    click_button "Refresh preview"

    expect(page).to have_content(I18n.t("tracks.preview.already_saved"))
    expect(default_labels).to eq([ "Your track (Senior)" ])
    expect(page).to have_button("Apply track", disabled: true)
    expect(page.evaluate_script("window.trackWrites")).to eq(1)
    expect(page).to have_no_css("#save-status")
  end
end
