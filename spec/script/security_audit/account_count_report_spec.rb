require "rails_helper"
require Rails.root.join("script/security_audit/account_count_report")

RSpec.describe AccountCountReport do
  let(:out) { StringIO.new }
  let(:report) { described_class.new(out: out) }

  def account(email, key: false, created_at: 1.year.ago)
    attributes = { email: email, name: "Name", created_at: created_at }
    attributes[:api_keys] = { "anthropic" => "sk-ant-test-key" } if key
    User.create!(attributes)
  end

  def exercise_for(user)
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q" } })
  end

  before do
    account("keyless@example.com")
    account("keyed-idle@example.com", key: true)
    generated = account("generated@example.com", key: true)
    exercise_for(generated)
    submitter = account("submitter@example.com", key: true)
    DailyResponse.create!(user: submitter, daily_exercise: exercise_for(submitter), date: Date.current,
                          answers: {}, submitted_at: Time.current)
    account("recent@example.com", created_at: 2.days.ago)
    account("gone@example.com", key: true).anonymize!
  end

  it "counts each group the signup decision reads" do
    expect(report.rows).to eq(
      "accounts (all)"                        => 6,
      "anonymized (deleted)"                  => 1,
      "active"                                => 5,
      "active, never added a key"             => 2,
      "active, key but never generated a set" => 1,
      "active, never generated a set"         => 3,
      "active, generated at least one set"    => 2,
      "active, submitted at least one day"    => 1,
      "created in the last 30 days"           => 1,
      "created in the last 30 days, no key"   => 1
    )
  end

  it "prints numbers only, never an email or a name" do
    report.report

    expect(out.string).to include("active, never added a key                2")
    expect(out.string).not_to include("@example.com", "Name")
  end

  it "runs its queries in a transaction that refuses writes" do
    expect {
      report.read_only { User.create!(email: "written@example.com", name: "Written") }
    }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
    expect(User.exists?(email: "written@example.com")).to be(false)
  end
end
