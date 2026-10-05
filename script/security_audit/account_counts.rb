# Read-only. Counts accounts for the open-signup question in the security
# audit. Prints numbers only, never an email or a name.
#
#   bin/rails runner script/security_audit/account_counts.rb
#   railway run --service web bin/rails runner script/security_audit/account_counts.rb
ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")

  active        = User.active
  with_key      = active.where.not(api_keys: nil)
  with_exercise = active.where(id: DailyExercise.select(:user_id))
  with_submit   = active.where(id: DailyResponse.where.not(submitted_at: nil).select(:user_id))

  rows = {
    "accounts (all)"                         => User.count,
    "anonymized (deleted)"                   => User.where.not(anonymized_at: nil).count,
    "active"                                 => active.count,
    "active, never added a key"              => active.where(api_keys: nil).count,
    "active, key but never generated a set"  => with_key.where.not(id: DailyExercise.select(:user_id)).count,
    "active, never generated a set"          => active.where.not(id: DailyExercise.select(:user_id)).count,
    "active, generated at least one set"     => with_exercise.count,
    "active, submitted at least one day"     => with_submit.count,
    "created in the last 30 days"            => User.where(created_at: 30.days.ago..).count,
    "created in the last 30 days, no key"    => active.where(api_keys: nil, created_at: 30.days.ago..).count
  }

  rows.each { |label, count| puts format("%-40s %d", label, count) }
  raise ActiveRecord::Rollback
end
