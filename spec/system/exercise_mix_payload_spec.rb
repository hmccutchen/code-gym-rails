require "rails_helper"

RSpec.describe "Exercise mix request bodies", type: :system do
  let(:user) { create_fake_provider_user }
  let(:layout) { %w[code_review design_comparison] }

  def record_profile_requests
    page.execute_script(<<~JS)
      window.__bodies = [];
      window.__previews = [];
      const passThrough = window.fetch;
      window.fetch = (url, options) => {
        const path = new URL(String(url), location.href).pathname;
        if (path === #{profile_path.to_json}) window.__bodies.push(JSON.parse(options.body));
        if (path === #{profile_track_preview_path.to_json}) window.__previews.push(JSON.parse(options.body));
        return passThrough(url, options);
      };
    JS
  end

  def bodies_without_version
    page.evaluate_script("window.__bodies").map { |b| b.deep_dup.tap { |c| c["user"]&.delete("section_kind_preferences_version") } }
  end

  def settle
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
  end

  it "keeps the mix payloads and sends the displayed confirmation only on explicit track Apply" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    record_profile_requests

    find("#weight-challenge").set(0)
    settle
    find("#exclude-challenge").click
    settle
    find(".mix-difficulty[data-kind='code_review'] input[value='senior']").click
    settle
    find("#lock-code_review").click
    settle
    find(".mix-difficulty[data-kind='code_review'] input[value='']").click
    settle
    mix = lambda do |weights, excluded, levels, locked|
      {
        "user" => {
          "section_kind_weights" => weights,
          "excluded_section_kinds" => excluded,
          "section_kind_levels" => levels,
          "locked_section_kinds" => locked
        },
        "layout" => layout
      }
    end
    expected_mix = [
      mix.({ "challenge" => 0.25 }, [], {}, []),
      mix.({ "challenge" => 0.25 }, %w[challenge], {}, []),
      mix.({ "challenge" => 0.25 }, %w[challenge], { "code_review" => "senior" }, []),
      mix.({ "challenge" => 0.25 }, %w[challenge], { "code_review" => "senior" }, %w[code_review]),
      mix.({ "challenge" => 0.25 }, %w[challenge], {}, [])
    ]
    expect(bodies_without_version).to eq(expected_mix)
    saved = user.reload.attributes
    find("#skill-level", visible: :all).select("Senior", visible: :all)
    expect(page).to have_button("Apply track", disabled: false)

    expect(page.evaluate_script("window.__previews")).to eq([ { "user" => { "skill_level" => "senior" } } ])
    expect(bodies_without_version).to eq(expected_mix)
    expect(user.reload.attributes).to eq(saved)

    click_button "Apply track"
    expect(page).to have_no_button("Apply track")
    settle

    expect(bodies_without_version).to eq(expected_mix + [
      { "user" => { "skill_level" => "senior" },
        "track_change" => { "from" => saved["skill_level"], "to" => "senior",
                            "preferences_version" => saved["section_kind_preferences_version"] } }
    ])
    expect(user.reload).to have_attributes(skill_level: "senior", section_kind_weights: { "challenge" => 0.25 },
                                           excluded_section_kinds: %w[challenge], section_kind_levels: {}, locked_section_kinds: [])
  end
end
