require "rails_helper"

RSpec.describe "Learner notes on a held set that an autosave moved", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key(email: "moved-notes@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) } }
  let(:yesterday) { Date.new(2026, 11, 17) }
  let!(:held) do
    DailyExercise.create!(user: user, date: yesterday, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" } })
  end

  around { |example| travel_to(Time.utc(2026, 11, 18, 15)) { example.run } }

  before do
    stub_env("LEARNER_NOTES" => "1", "HELD_SET_LOOKUP" => "1")
    user.update!(paused_generation_at: yesterday.in_time_zone("UTC") + 9.hours)
    login_as(user)
  end

  def raw_reply
    { "items" => [ { "concept" => "n_plus_one", "bucket" => "ruby_rails", "kind" => "concept", "label" => "Asked where the query runs.",
                     "evidence" => [ { "date" => "2026-11-01", "source" => "note" } ] } ] }
  end

  it "stamps evidence and came_up_on with the move day, and deleting the note forgets the items citing it" do
    scope = held.draft_scope
    patch learner_note_path, params: { learner_note: "Lost on where the query runs.", draft_scope: scope }, as: :json
    expect(response).to have_http_status(:ok)
    expect(held.reload.date).to eq(Date.current)

    post responses_path, params: { response: { draft_scope: scope, answers: { code_review: "It loads per row." },
                                               section_ratings: { code_review: "right_level" }, submit: "1" } }, as: :json
    expect(response.parsed_body).to include("submitted" => true)

    allow_any_instance_of(AiService).to receive(:extract_learner_items) do |_service, _user, day:, buckets:, **|
      LearnerItemsReply.parse(raw_reply, day: day, buckets: buckets)
    end
    ExtractLearnerItemsJob.perform_now(user_id: user.id, daily_exercise_id: held.id,
                                       daily_response_id: held.daily_response.id, run: "fallback")

    item = LearnerItem.find_by!(user: user)
    expect(item.evidence.map { |reference| reference["date"] }).to eq([ Date.current.iso8601 ])
    expect(item.came_up_on).to eq([ Date.current.iso8601 ])

    delete note_account_learner_note_path(LearnerNote.find_by!(daily_exercise: held))

    expect(LearnerItem.where(id: item.id)).to be_empty
  end
end
