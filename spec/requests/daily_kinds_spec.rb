require "rails_helper"

RSpec.describe "Swapping a daily section kind", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) { create_fake_provider_user }

  before { login_as(user) }

  def swap(place, kind, version: user.reload.section_kind_preferences_version)
    patch daily_kind_path(place), params: { kind: kind, section_kind_preferences_version: version }.to_json, headers: json
  end

  def body = JSON.parse(response.body)

  it "saves the pair and answers with the reply, the new pair and the new version" do
    swap(1, "architecture")

    expect(response).to have_http_status(:ok)
    expect(body).to eq(
      "status" => "saved", "message" => "Saved. This starts with your next set.", "want_it_today" => nil,
      "want_it_today_link" => nil, "panels" => {},
      "daily_kinds" => %w[code_review architecture], "section_kind_preferences_version" => user.reload.section_kind_preferences_version
    )
    expect(user.daily_kind_swap_events.sole).to have_attributes(from_kind: "design_comparison", to_kind: "architecture")
  end

  it "renders a fresh panel for every daily card on today's set, each carrying the new version" do
    exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                                     problem_set: { "code_review" => { "question" => "q" }, "design_comparison" => { "question" => "q" } },
                                     plan_notes: { "daily_kinds" => %w[code_review design_comparison], "size" => 2 })
    swap(1, "architecture")

    version = user.reload.section_kind_preferences_version
    expect(body["panels"].keys).to eq(%w[0 1])
    expect(body["panels"].values).to all(include(%(data-version="#{version}")))
    expect(body["panels"]["1"]).to include("Swap Design Comparison").and include("Your next set uses #{I18n.t("sections.architecture.name")} here.")
      .and include(%(id="daily-kind-1-design_comparison"))
    expect(body["panels"]["0"]).to include("Already a daily section")
    expect(exercise.reload.problem_set.keys).to eq(%w[code_review design_comparison])
  end

  it "names the button the want-it-today line points at only when that line is offered" do
    DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q" }, "design_comparison" => { "question" => "q" } },
                          plan_notes: { "daily_kinds" => %w[code_review design_comparison], "size" => 2 })
    swap(1, "architecture")

    expect(body).to include("want_it_today" => I18n.t("daily_kinds.swap.want_it_today"),
                            "want_it_today_link" => I18n.t("daily_kinds.picker.generate_link"))
  end

  it "refuses a pair the rules do not allow with a 422 naming the reason" do
    swap(0, "design_comparison")

    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to include("status" => "already_daily", "error" => "That kind is already a daily section.",
                            "daily_kinds" => %w[code_review design_comparison])
    expect(user.daily_kind_swap_events).to be_empty
  end

  it "answers an unexpected validation failure with a 422, not a server error" do
    user.update_columns(daily_section_count: 9)

    swap(1, "architecture")

    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to include("status" => "invalid", "daily_kinds" => %w[code_review design_comparison])
  end

  it "refuses a page behind the stored version with a 409 carrying the current pair" do
    stale = user.section_kind_preferences_version
    user.update!(daily_section_kinds: %w[pattern design_comparison])

    swap(1, "architecture", version: stale)

    expect(response).to have_http_status(:conflict)
    expect(body).to include("status" => "stale", "daily_kinds" => %w[pattern design_comparison],
                            "section_kind_preferences_version" => user.reload.section_kind_preferences_version)
    expect(user.daily_section_kinds).to eq(%w[pattern design_comparison])
  end

  it "sends a stale page fresh panels for the stored pair and version, and a 422 none" do
    DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q" }, "design_comparison" => { "question" => "q" } },
                          plan_notes: { "daily_kinds" => %w[code_review design_comparison], "size" => 2 })
    stale = user.section_kind_preferences_version
    user.update!(daily_section_kinds: %w[pattern design_comparison])

    swap(1, "architecture", version: stale)

    expect(body["panels"].keys).to eq(%w[0 1])
    expect(body["panels"]["0"]).to include(%(data-version="#{user.reload.section_kind_preferences_version}"))
      .and include("Swap Code Review").and include("Your next set uses #{I18n.t("sections.pattern.name")} here.")

    swap(1, "design_comparison")
    expect(response).to have_http_status(:unprocessable_content)
    expect(body).not_to have_key("panels")
  end

  it "keeps a weight on a kind through swap, Exercise mix edit and swap back" do
    user.update!(section_kind_weights: { "challenge" => 2.0 })

    swap(1, "challenge")
    patch profile_path, params: { user: { section_kind_weights: { "architecture" => 0.5 }, excluded_section_kinds: [],
                                          section_kind_preferences_version: user.reload.section_kind_preferences_version } },
                        as: :json
    expect(response).to have_http_status(:ok)
    swap(1, "design_comparison")

    expect(user.reload.section_kind_weights).to eq("challenge" => 2.0, "architecture" => 0.5)
    expect(user.daily_section_kinds).to eq([])
  end
end
