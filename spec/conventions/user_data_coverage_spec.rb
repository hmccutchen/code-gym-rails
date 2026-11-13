require "rails_helper"

RSpec.describe "What happens to each row that refers to a user when the account is deleted" do
  OUTSIDE_THE_SCHEMA = {
    "job arguments" => "user ids and record GlobalIDs inside solid_queue_jobs.arguments; AccountDeletion deletes the unfinished ones it can match",
    "concurrency keys" => "user ids inside solid_queue_jobs.concurrency_key, solid_queue_blocked_executions.concurrency_key and solid_queue_semaphores.key, which expire with the job's permit",
    "failed-job error text" => "user ids inside solid_queue_failed_executions.error, which goes with its job row",
    "failed jobs" => "a job running at deletion that then fails for another reason stays failed, naming the user, until someone discards it",
    "cache keys" => "emails, IP addresses and user ids inside solid_cache_entries.key, removed by config/cache.yml's max_age",
    "JSON columns" => "ids inside JSON columns such as concept_masteries.practice_requests, deleted with their row",
    "cookies" => "the signed-in session cookie, which stops resolving once the users row is gone",
    "browser storage" => "the answer draft copy in localStorage and the pull-refresh note in sessionStorage",
    "logs" => "user ids in application and Railway logs",
    "backups" => "Railway database backups",
    "Resend" => "login code and review emails held by Resend",
    "AI providers" => "prompts and replies held by Anthropic, Google and OpenAI"
  }.freeze

  def connection = ActiveRecord::Base.connection

  def uncovered(references)
    references.reject { |ref| AccountData::FATES[ref.table]&.columns&.include?(ref.column) }.map { |ref| [ ref.table, ref.column ] }.sort
  end

  it "gives every table and column that refers to a user a fate" do
    expect(uncovered(user_references)).to eq([]), "give these a fate in AccountData::FATES before deletion can be trusted"
  end

  it "names only tables the schema has" do
    expect(AccountData::FATES.keys - schema_tables).to eq([])
  end

  it "gives each entry a known fate and a one-line reason" do
    AccountData::FATES.each_value do |fate|
      expect(AccountData::KINDS).to include(fate.kind)
      expect(fate.reason).to match(/\A[^\n]{10,}\z/)
    end
  end

  it "indexes every column the deletion finds a person's rows by" do
    unindexed = AccountData::FATES.flat_map do |table, fate|
      fate.columns.reject { |column| connection.indexes(table).any? { |index| Array(index.columns).first == column } }
                  .map { |column| "#{table}.#{column}" }
    end

    expect(unindexed).to eq([])
  end

  def deleted_before_parent_violations(fates)
    deleting = fates.select { |_, fate| %i[delete delete_unfinished].include?(fate.kind) }.keys
    deleting.flat_map do |child|
      connection.foreign_keys(child).map(&:to_table).select { |parent| deleting.include?(parent) && parent != child }
                .reject { |parent| deleting.index(child) < deleting.index(parent) }.map { |parent| [ child, parent ] }
    end.sort
  end

  it "deletes every child table before the table its foreign key points at" do
    expect(deleted_before_parent_violations(AccountData::FATES)).to eq([])
  end

  it "fails on a parent planted ahead of its child in the deletion order" do
    planted = AccountData::FATES.slice("daily_exercises").merge(AccountData::FATES)

    expect(deleted_before_parent_violations(planted)).to eq([
      [ "daily_responses", "daily_exercises" ], [ "duck_threads", "daily_exercises" ], [ "judge_solves", "daily_exercises" ]
    ])
  end

  it "finds the follow-ups only through the foreign key to a table it already knows is the user's" do
    expect(user_references.map { |ref| [ ref.table, ref.column, ref.target ] }).to include(
      [ "review_follow_ups", "daily_response_id", "daily_responses" ], [ "suggested_concepts", "reviewed_by_id", "users" ],
      [ "users", "email", :email ], [ "judge_solves", "user_id", "users" ], [ "duck_threads", "daily_exercise_id", "daily_exercises" ])
  end

  it "fails on a planted table found by each of the four routes" do
    connection.create_table(:planted_notes) { |t| t.bigint :author_id }
    connection.add_foreign_key :planted_notes, :users, column: :author_id
    connection.create_table(:planted_replies) { |t| t.bigint :planted_note_id }
    connection.add_foreign_key :planted_replies, :planted_notes
    connection.create_table(:planted_contacts) do |t|
      t.string :backup_email
      t.bigint :owner_ref
    end
    planted_model = Class.new(ApplicationRecord) do
      self.table_name = "planted_contacts"
      belongs_to :owner, class_name: "User", foreign_key: :owner_ref
    end

    expect(uncovered(user_references(models: record_models + [ planted_model ]))).to eq([
      [ "planted_contacts", "backup_email" ], [ "planted_contacts", "owner_ref" ],
      [ "planted_notes", "author_id" ], [ "planted_replies", "planted_note_id" ]
    ])
  end

  it "lets only AccountDeletion read the fate list, since the isolation specs allow its file" do
    readers = Rails.root.glob("app/**/*.rb").select { |path| path.read.match?(/\bAccountData\b/) }
    expect(readers.map { |path| path.relative_path_from(Rails.root).to_s }).to contain_exactly(
      "app/models/account_data.rb", "app/services/account_deletion.rb"
    )
  end

  it "keeps the hand-kept list of what the schema walk cannot see" do
    expect(OUTSIDE_THE_SCHEMA.keys).to contain_exactly("job arguments", "concurrency keys", "failed-job error text", "failed jobs", "cache keys",
                                                       "JSON columns", "cookies", "browser storage", "logs", "backups",
                                                       "Resend", "AI providers")
  end
end
