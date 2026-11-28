require "rails_helper"

RSpec.describe "Setup after retiring daily counts", type: :system do
  let(:user) do
    create_fake_provider_user(daily_section_count: 3).tap do |record|
      record.update!(daily_section_kinds: %w[code_review design_comparison challenge])
    end
  end

  it "retains the historical count while saving the time zone across reloads" do
    visit_as(user)
    visit setup_path
    wait_for_js

    expect(page).to have_no_css("#daily-sections", visible: :all)
    select "Pacific", from: "tz-select", visible: :all
    wait_for { user.reload.time_zone == "America/Los_Angeles" }

    visit setup_path

    expect(find("#tz-select", visible: :all).value).to eq("America/Los_Angeles")
    expect(user.reload.daily_section_count).to eq(3)
    expect(user.daily_section_kinds).to eq(%w[code_review design_comparison challenge])
  end

  it "saves a historical extra's frequency without changing the stored count or kind list" do
    visit_as(user)
    visit setup_path
    wait_for_js
    find("#exercise-mix summary").click unless find("#exercise-mix")[:open]

    page.execute_script(<<~JS)
      const slider = document.getElementById("weight-challenge");
      slider.value = "4";
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS
    wait_for { user.reload.section_kind_weights == { "challenge" => KindPreferences::MULTIPLIERS.last } }

    visit setup_path

    expect(find("#weight-challenge", visible: :all).value).to eq("4")
    expect(user.reload.daily_section_count).to eq(3)
    expect(user.daily_section_kinds).to eq(%w[code_review design_comparison challenge])
  end
end
