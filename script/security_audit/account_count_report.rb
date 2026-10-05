# Counts accounts for the open-signup question in the security audit. Prints
# numbers only, never an email or a name, inside a read-only transaction that
# is rolled back, so nothing it runs can write.
class AccountCountReport
  def initialize(out: $stdout)
    @out = out
  end

  def report
    read_only { rows.each { |label, count| @out.puts format("%-40s %d", label, count) } }
  end

  def read_only
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      yield
      raise ActiveRecord::Rollback
    end
  end

  def rows
    active          = User.active
    never_generated = active.where.not(id: DailyExercise.select(:user_id))

    {
      "accounts (all)"                        => User.count,
      "anonymized (deleted)"                  => User.where.not(anonymized_at: nil).count,
      "active"                                => active.count,
      "active, never added a key"             => active.where(api_keys: nil).count,
      "active, key but never generated a set" => never_generated.where.not(api_keys: nil).count,
      "active, never generated a set"         => never_generated.count,
      "active, generated at least one set"    => active.where(id: DailyExercise.select(:user_id)).count,
      "active, submitted at least one day"    => active.where(id: DailyResponse.where.not(submitted_at: nil).select(:user_id)).count,
      "created in the last 30 days"           => User.where(created_at: 30.days.ago..).count,
      "created in the last 30 days, no key"   => active.where(api_keys: nil, created_at: 30.days.ago..).count
    }
  end
end
