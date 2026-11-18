require "rails_helper"
require "fugit"

RSpec.describe SweepLearnerNotesJob do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:today) { Date.new(2026, 11, 18) }

  around { |example| travel_to(Time.utc(2026, 11, 18, 3)) { example.run } }

  def note_on(date)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => { "question" => "Find the bug" } })
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "A note.")
  end

  def item(status:, closed_on: nil, concept: "n_plus_one")
    LearnerItem.create!(user: user, concept: concept, bucket: "ruby_rails", kind: "concept", label: "Practise it.",
                        status: status, closed_on: closed_on, expires_on: today + 14,
                        evidence: [ { "date" => (today - 1).iso8601, "source" => "note" } ], came_up_on: [ (today - 1).iso8601 ])
  end

  it "deletes notes once their set is more than 365 days old, as duck threads are, and keeps the rest" do
    swept = note_on(today - LearnerNote::KEPT_FOR - 1.day)
    kept = note_on(today - LearnerNote::KEPT_FOR)

    described_class.perform_now

    expect(LearnerNote.pluck(:id)).to eq([ kept.id ])
    expect(DailyExercise.exists?(swept.daily_exercise_id)).to be(true)
    expect(LearnerNote::KEPT_FOR).to eq(365.days)
  end

  it "deletes closed items 90 days after they closed, of every closed status, and keeps open ones" do
    swept = %w[used dismissed expired].each_with_index.map do |status, index|
      item(status: status, closed_on: today - 91, concept: %w[n_plus_one memoization caching][index])
    end
    kept_closed = item(status: "dismissed", closed_on: today - 90, concept: "service_objects")
    kept_open = item(status: "open")

    described_class.perform_now

    expect(LearnerItem.where(id: swept.map(&:id))).to be_empty
    expect(LearnerItem.pluck(:id)).to contain_exactly(kept_closed.id, kept_open.id)
    expect(LearnerItem::KEPT_AFTER_CLOSE).to eq(90.days)
  end

  it "leaves no trace of a swept dismissed item, so a later item for its key gets no returned_after" do
    item(status: "dismissed", closed_on: today - 91)
    described_class.perform_now

    reply = LearnerItemsReply::Item.new(concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", term: nil,
                                        label: "Practise it again.",
                                        evidence: [ { "date" => today.iso8601, "source" => "note" } ])
    LearnerItem.merge!(user, [ reply ], set_date: today)

    expect(LearnerItem.sole).to have_attributes(status: "open", returned_after: nil)
  end

  it "runs daily in production on the general queue" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "sweep_learner_notes")

    expect(schedule).to include("class" => described_class.name)
    expect(Fugit.parse_cron(schedule["schedule"]).rough_frequency).to eq(1.day.to_i)
    expect(described_class.queue_name).to eq("default")
  end
end
