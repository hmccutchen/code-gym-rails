require "rails_helper"

RSpec.describe CoverageException::History do
  let(:user) { User.create!(email: "coverage-history@example.com", name: "History") }

  def exercise(date, keys, plan_notes: {})
    user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
                                 problem_set: keys.index_with { |key| { "concept" => "x", "title" => key } },
                                 plan_notes: plan_notes)
  end

  it "reads each delivered kind's last date, the planned additions and the oldest date in one query" do
    exercise(Date.current - 10, %w[code_review design_comparison plan_review])
    exercise(Date.current - 3, %w[code_review design_comparison pattern])
    exercise(Date.current - 2, %w[code_review design_comparison pattern])

    queries = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end
    history = described_class.for(user)
    ActiveSupport::Notifications.unsubscribe(sub)

    expect(queries).to eq(1)

    expect(history.last_seen).to include("pattern" => Date.current - 2, "plan_review" => Date.current - 10)
    expect(history.first_date).to eq(Date.current - 10)
  end

  it "counts a planned addition whose section was later dropped, and does not count the kind as seen" do
    exercise(Date.current - 1, %w[code_review design_comparison], plan_notes: { "coverage" => "plan_review" })

    history = described_class.for(user)

    expect(history.coverage_dates).to eq([ Date.current - 1 ])
    expect(history.last_seen).not_to have_key("plan_review")
  end

  it "leaves today's row out, so a regeneration plans as the first generation did" do
    exercise(Date.current, %w[code_review design_comparison plan_review], plan_notes: { "coverage" => "plan_review" })

    history = described_class.for(user)

    expect(history.coverage_dates).to eq([])
    expect(history.first_date).to be_nil
  end
end
