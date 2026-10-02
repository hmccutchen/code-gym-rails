require "rails_helper"

RSpec.describe CoverageException::History do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { User.create!(email: "coverage-history@example.com", name: "History") }

  around { |example| travel_to(Time.zone.local(2026, 10, 7, 9)) { example.run } }

  def exercise(date, keys, plan_notes: {})
    user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
                                 problem_set: keys.index_with { |key| { "concept" => "x", "title" => key } },
                                 plan_notes: plan_notes)
  end

  def count_queries
    queries = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  describe ".for" do
    it "reads each delivered kind's last date and the oldest date in one query" do
      exercise(Date.current - 10, %w[code_review design_comparison plan_review])
      exercise(Date.current - 3, %w[code_review design_comparison pattern])
      exercise(Date.current - 2, %w[code_review design_comparison pattern])

      history = nil
      expect(count_queries { history = described_class.for(user, coverage_dates: []) }).to eq(1)

      expect(history.last_seen).to include("pattern" => Date.current - 2, "plan_review" => Date.current - 10)
      expect(history.first_date).to eq(Date.current - 10)
    end

    it "does not count a dropped addition's kind as seen" do
      exercise(Date.current - 1, %w[code_review design_comparison], plan_notes: { "coverage" => "plan_review" })

      expect(described_class.for(user, coverage_dates: []).last_seen).not_to have_key("plan_review")
    end

    it "leaves today's row out, so a regeneration plans as the first generation did" do
      exercise(Date.current, %w[code_review design_comparison plan_review])

      expect(described_class.for(user, coverage_dates: []).first_date).to be_nil
    end
  end

  describe ".recent_coverage_dates" do
    it "reads planned additions inside the cap's window only, a dropped one included" do
      exercise(Date.current - 1, %w[code_review design_comparison], plan_notes: { "coverage" => "plan_review" })
      exercise(Date.current - 2, %w[code_review design_comparison])
      exercise(Date.current - 9, %w[code_review design_comparison pattern], plan_notes: { "coverage" => "pattern" })
      exercise(Date.current, %w[code_review design_comparison pattern], plan_notes: { "coverage" => "pattern" })

      expect(described_class.recent_coverage_dates(user)).to eq([ Date.current - 1 ])
    end
  end
end
