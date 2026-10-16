require "rails_helper"

RSpec.describe "Learning track dismissal events", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) do
    create_user_with_key.tap do |account|
      account.update!(section_kind_levels: ExerciseSection.keys.index_with { "junior" })
    end
  end

  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  def dismiss(kinds, **extra)
    post level_suggestion_dismissal_path, params: { kinds: kinds, **extra }.to_json, headers: json
  end

  it "records a Not now with the offered move and the evidence behind it when no reason is sent" do
    reviewed_level_days(user, "code_review", "junior", 5, ending: Date.current - 1)
    login_as(user)

    dismiss([ "code_review" ])

    expect(response).to have_http_status(:ok)
    expect(user.level_suggestion_events.sole).to have_attributes(
      kind: "code_review", action: "dismissed", source: nil, from_level: "junior", to_level: "mid_level",
      window_size: 5, favourable: 5, too_hard_latest3: 0, newest_result_on: Date.current - 1
    )
  end

  it "records removed bundle members with no offered move" do
    login_as(user)

    dismiss(%w[pattern architecture], reason: "removed")

    expect(response).to have_http_status(:ok)
    expect(user.level_suggestion_events.pluck(:kind, :action, :to_level, :window_size)).to contain_exactly(
      [ "pattern", "removed", nil, 0 ], [ "architecture", "removed", nil, 0 ]
    )
  end

  it "counts the evidence before this dismissal's cutoff" do
    reviewed_level_days(user, "code_review", "junior", 2, ending: Date.current - 1)
    user.update!(level_suggestion_cutoffs: { "code_review" => { "level" => "junior", "through" => (Date.current - 2).iso8601 } })
    login_as(user)

    dismiss([ "code_review" ])

    expect(user.level_suggestion_events.sole.window_size).to eq(1)
    expect(user.reload.level_suggestion_cutoffs["code_review"]["through"]).to eq((Date.current - 1).iso8601)
  end

  it "writes no second row when the same Not now is sent again with no newer results" do
    reviewed_level_days(user, "code_review", "junior", 5, ending: Date.current - 1)
    login_as(user)

    dismiss([ "code_review" ])
    dismiss([ "code_review" ])

    expect(response).to have_http_status(:ok)
    expect(user.level_suggestion_events.count).to eq(1)
  end

  it "writes a new row when a newer reviewed day moves the cutoff forward" do
    reviewed_level_days(user, "code_review", "junior", 5, ending: Date.current - 2)
    login_as(user)
    dismiss([ "code_review" ])

    reviewed_level_days(user, "code_review", "junior", 1, ending: Date.current - 1)
    dismiss([ "code_review" ])

    expect(response).to have_http_status(:ok)
    expect(user.level_suggestion_events.order(:id).pluck(:newest_result_on)).to eq(
      [ Date.current - 2, Date.current - 1 ]
    )
    expect(user.reload.level_suggestion_cutoffs["code_review"]["through"]).to eq((Date.current - 1).iso8601)
  end

  [ "later", "", [ "not_now" ] ].each do |reason|
    it "refuses the reason #{reason.inspect} and writes nothing" do
      login_as(user)

      dismiss([ "code_review" ], reason: reason)

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.level_suggestion_events).to be_empty
      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end
  end

  it "dismisses a mid-level kind with a cutoff at its current target" do
    user.update!(section_kind_levels: user.section_kind_levels.merge("pattern" => "mid_level"))
    travel 1.day
    login_as(user)

    dismiss([ "pattern" ])

    expect(response).to have_http_status(:ok)
    expect(user.reload.level_suggestion_cutoffs["pattern"]).to eq(
      "level" => "mid_level", "through" => Date.current.iso8601
    )
    expect(user.level_suggestion_events.where(action: "dismissed").sole.from_level).to eq("mid_level")
  end

  it "refuses a principal engineer kind, which no suggestion moves" do
    user.update!(section_kind_levels: user.section_kind_levels.merge("pattern" => "principal_engineer"))
    login_as(user)

    dismiss([ "pattern" ])

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.level_suggestion_events.where.not(action: "applied")).to be_empty
  end

  it "writes no event and no cutoff when the dashboard shows a pending proposal" do
    reviewed_level_days(user, "code_review", "junior", 5)
    login_as(user)

    expect { get root_path }.not_to change(LevelSuggestionEvent, :count)
    expect(Nokogiri::HTML(response.body).at_css("#level-suggestion")).to be_present
    expect(user.reload.level_suggestion_cutoffs).to eq({})
  end

  describe "a refused write" do
    it "builds a valid row for every kind and reason" do
      ExerciseSection.keys.each do |kind|
        %w[dismissed removed].each do |action|
          rows = LevelSuggestionEvent.dismissal_rows(user, kinds: [ kind ], action: action, results: {})
          expect(rows.map { |row| user.level_suggestion_events.build(row) }).to all(be_valid)
        end
      end
    end

    it "answers 422 and writes nothing when the user row no longer validates" do
      login_as(user)
      user.update_column(:skill_level, "developing")

      dismiss([ "code_review" ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("status" => "error")
      expect(user.reload.level_suggestion_cutoffs).to eq({})
      expect(user.level_suggestion_events).to be_empty
    end
  end
end
