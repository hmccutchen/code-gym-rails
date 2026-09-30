# Usage: bin/rails runner script/prepare_junior_ladders.rb <operator_user_id> [--run]
# Without --run, no jobs are queued and no account or reference is written.
require_relative "junior_ladder_preparation"

usage = "Usage: bin/rails runner script/prepare_junior_ladders.rb <operator_user_id> [--run]"
abort(usage) unless ARGV.first&.match?(/\A[1-9]\d*\z/) && (ARGV.size == 1 || ARGV.drop(1) == [ "--run" ])
operator_id = Integer(ARGV.first, 10)

preparation = JuniorLadderPreparation.new(operator_id: operator_id)
preparation.report
preparation.run! if ARGV.last == "--run"
