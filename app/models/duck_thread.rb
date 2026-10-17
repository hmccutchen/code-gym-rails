# Design notes: docs/code-notes/app/models/duck_thread.md
class DuckThread < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  KEPT_FOR = 365.days

  scope :expired, ->(today = Date.current) { where(daily_exercise: DailyExercise.where(date: ...(today - KEPT_FOR))) }

  def self.for(exercise)
    exercise.duck_thread || new(user: exercise.user, daily_exercise: exercise, draft_scope: exercise.draft_scope)
  end

  # Returns the new version, or nil when the thread, the set or the submitted state moved since the turn was read.
  def self.append!(exercise, section, message:, answer:, expected_version:, expected_scope:)
    under_locks(exercise) do |response|
      next if response&.submitted? || exercise.draft_scope != expected_scope

      write(row_for(exercise)) do |row|
        next unless row.version_for(section) == expected_version

        pair = [ { "role" => "user", "content" => message }, { "role" => "assistant", "content" => answer } ]
        row.put(section, "turns" => row.stored_turns(section) + pair, "version" => expected_version + 1)
      end
    end
  end

  # Returns the new version, or nil when the day was submitted or the account deleted while the Clear waited.
  def self.clear!(exercise, section)
    under_locks(exercise) do |response|
      next if response&.submitted?

      write(row_for(exercise)) do |row|
        cleared = row.cleared_count(section) + (row.stored_turns(section).empty? ? 0 : 1)
        row.put(section, "turns" => [], "version" => row.version_for(section) + 1, "cleared" => cleared)
      end
    end
  end

  # The owner first, as User#carry_forward does: an account deleted while a reply was on its way stays deleted.
  def self.under_locks(exercise, &)
    transaction do
      next if User.lock("FOR SHARE").find(exercise.user_id).anonymized?

      exercise.with_response_locked(&)
    end
  end
  private_class_method :under_locks

  def self.row_for(exercise)
    transaction(requires_new: true) do
      find_or_create_by!(daily_exercise: exercise) do |row|
        row.user        = exercise.user
        row.draft_scope = exercise.draft_scope
      end
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(daily_exercise: exercise)
  end
  private_class_method :row_for

  def self.write(row)
    row.with_lock do
      row.restart unless row.current?
      result = yield row
      row.save! if row.changed?
      result
    end
  end
  private_class_method :write

  def turns_for(section)
    stored_turns(section).map { |turn| { role: turn["role"], content: turn["content"] } }
  end

  def user_turn_count(section) = stored_turns(section).count { |turn| turn["role"] == "user" }
  def byte_size(section)       = stored_turns(section).sum { |turn| turn["content"].to_s.bytesize }
  def version_for(section)     = entry(section)["version"].to_i
  def cleared_count(section)   = entry(section)["cleared"].to_i
  def stored_turns(section)    = Array(entry(section)["turns"])

  def current? = draft_scope == daily_exercise.draft_scope

  def restart
    self.threads     = {}
    self.draft_scope = daily_exercise.draft_scope
  end

  def put(section, attrs)
    self.threads = threads.merge(section.to_s => entry(section).merge(attrs))
    attrs["version"]
  end

  private

  def entry(section)
    current? ? (threads[section.to_s] || {}) : {}
  end
end
