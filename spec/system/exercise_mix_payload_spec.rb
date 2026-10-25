require "rails_helper"

RSpec.describe "Exercise mix request bodies", type: :system do
  let(:user) { create_fake_provider_user }
  let(:layout) { %w[code_review design_comparison] }

  def record_requests_to(path)
    page.execute_script(<<~JS)
      window.__bodies = [];
      const passThrough = window.fetch;
      window.fetch = (url, options) => {
        if (new URL(String(url), location.href).pathname === #{path.to_json}) window.__bodies.push(JSON.parse(options.body));
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

  it "sends the same mix and track payloads as before the restyle" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    record_requests_to(profile_path)

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
    find("#skill-level", visible: :all).select("Junior", visible: :all)
    settle

    mix = ->(weights, excluded, levels, locked) { { "user" => { "section_kind_weights" => weights, "excluded_section_kinds" => excluded, "section_kind_levels" => levels, "locked_section_kinds" => locked }, "layout" => layout } }
    expect(bodies_without_version).to eq([
      mix.({ "challenge" => 0.25 }, [], {}, []),
      mix.({ "challenge" => 0.25 }, %w[challenge], {}, []),
      mix.({ "challenge" => 0.25 }, %w[challenge], { "code_review" => "senior" }, []),
      mix.({ "challenge" => 0.25 }, %w[challenge], { "code_review" => "senior" }, %w[code_review]),
      mix.({ "challenge" => 0.25 }, %w[challenge], {}, []),
      { "user" => { "skill_level" => "junior" } }
    ])
  end
end
