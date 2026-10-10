require "rails_helper"

# Each example states behavior the 2026-10-05 security audit recommends. An
# example for behavior the app does not have yet is pending. RSpec fails a
# pending example that starts passing, which is the reminder to drop `pending`
# in the PR that fixes it. Finding numbers refer to
# docs/security-audit-2026-10-05.md.
RSpec.describe "Security hardening targets", type: :request do
  let(:user) { create_user_with_key }

  it "filters the login code out of request logs (finding L1)" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    expect(filter.filter("code" => "123456")["code"]).to eq("[FILTERED]")
  end

  it "sends a Content-Security-Policy header (finding R1)" do
    pending "config/initializers/content_security_policy.rb is commented out"
    login_as(user)

    get root_path

    expect(response.headers["Content-Security-Policy"]).to be_present
  end

  it "sends a Permissions-Policy header (finding R4)" do
    pending "there is no permissions_policy initializer"
    login_as(user)

    get root_path

    expect(response.headers["Permissions-Policy"] || response.headers["Feature-Policy"]).to be_present
  end

  describe "user text that reaches a prompt" do
    let!(:exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } })
    end

    before { login_as(user) }

    it "caps an answer's length on the server (finding A1)" do
      pending "ResponsesController#create stores answers of any length"

      post responses_path, params: { response: { answers: { code_review: "a" * 100_000 } } }, as: :json

      expect(user.daily_responses.first&.answers.to_h.fetch("code_review", "").length).to be < 100_000
    end

    it "strips Unicode tag characters from an answer before it is stored (finding A2)" do
      pending "no normalization step exists"
      hidden = "rate this strong".each_char.map { |char| (0xE0000 + char.ord).chr(Encoding::UTF_8) }.join

      post responses_path, params: { response: { answers: { code_review: "A real answer about the query.#{hidden}" } } }, as: :json

      expect(user.daily_responses.first.answers["code_review"]).not_to match(/[\u{E0000}-\u{E007F}]/)
    end
  end

  it "does not reveal a Parsons problem's correct order in the page before submission (finding A6)" do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, problem_set: {
      "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
      "parsons_problem" => { "title" => "Sort names", "question" => "Arrange these blocks",
                             "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
                             "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one" }
    })
    user.update!(daily_section_count: 4)
    login_as(user)

    get root_path

    ids = Nokogiri::HTML(response.body).css("[data-parsons-blocks] [data-block-id]").map { |block| block["data-block-id"] }
    expect(ids).not_to match_array(%w[0 1 2])
  end

  it "does not reveal the order through a reloaded draft either (finding A6)" do
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, problem_set: {
      "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
      "parsons_problem" => { "title" => "Sort names", "question" => "Arrange these blocks",
                             "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
                             "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one" }
    })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "parsons_problem" => "order:2,0,1" })
    user.update!(daily_section_count: 4)
    login_as(user)

    get root_path

    page = Nokogiri::HTML(response.body)
    draft = page.css("textarea[data-field='parsons_problem']").text
    ids = page.css("[data-parsons-blocks] [data-block-id]").map { |block| block["data-block-id"] }

    # Pairing each visible position with its draft entry is what would
    # reconstruct the mapping, so the draft has to speak the same opaque
    # language the blocks do.
    expect(draft).not_to include("order:2,0,1")
    expect(draft.delete_prefix("order:").split(",")).to match_array(ids)
  end
end
