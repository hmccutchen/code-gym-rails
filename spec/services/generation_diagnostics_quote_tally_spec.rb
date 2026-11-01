require "rails_helper"

RSpec.describe GenerationDiagnostics, "quote tally on [planted_key] lines" do
  let(:user) { User.create!(email: "quote-tally@example.com", name: "Quote Tally") }

  def logged_lines
    lines = []
    allow(Rails.logger).to receive(:info) { |message| lines << message.to_s }
    yield
    lines
  end

  def tally(spans) = PlantedKey.quote_tally([ spans ], within: [ "allow(Adoption).to receive(:create!)\nAdoptPet.call" ], scenario: "Jobs use `Redis`.", language: "ruby_rails")

  it "logs the four counts on the key's line, and no span text" do
    quotes = tally("`AdoptPet.call` and `Adoption.create!` and `Redis` and `:null_store`")
    note = ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "quote_missing", quotes: quotes)

    lines = logged_lines { described_class.new(user).key_notes([ note ], attempt: "draft", code_review_mode: :test_file) }

    expect(lines).to eq([ "[planted_key] answer_key=quote_missing kind=code_review language=ruby_rails attempt=draft " \
                          "code_review_mode=test_file verbatim=1 reference=1 scenario=1 unresolved=1 user=#{user.id}" ])
    expect(lines.sole).not_to include("null_store", "AdoptPet", "Redis")
  end

  it "logs no counts for a note without a tally, so a dropped key's line is unchanged" do
    note = ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "missing", quotes: nil)

    lines = logged_lines { described_class.new(user).key_notes([ note ], attempt: "draft", code_review_mode: :application_code) }

    expect(lines).to eq([ "[planted_key] answer_key=missing kind=code_review language=ruby_rails attempt=draft " \
                          "code_review_mode=application_code user=#{user.id}" ])
  end
end
