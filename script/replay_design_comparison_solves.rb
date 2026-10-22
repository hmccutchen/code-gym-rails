# Writes judge_solves records only and never changes an exercise; see docs/code-notes/script/design_comparison_replay.md.
USAGE = <<~TEXT.freeze
  bin/rails runner script/replay_design_comparison_solves.rb
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/replay_design_comparison_solves.rb --run [--rejudge]
  bin/rails runner script/replay_design_comparison_solves.rb --synthesize N --user ID
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/replay_design_comparison_solves.rb --synthesize N --user ID --run

  (no flag)       dry run: counts by week and by user, first and last date, worst-case cost bound; no provider call
  --run           make the calls: judge every stored design comparison not yet replayed, one at a time
  --rejudge       with --run, judge sections already replayed again
  --synthesize N  bring the synthetic records up to N, spread across the rungs and the vocabulary; without --run
                  it prints the plan by rung and the worst-case bound only, and a restart continues where it stopped.
                  --user names the account whose plan and time zone the drafts are built from
TEXT

require "optparse"
require_relative "design_comparison_replay"

options = {}
OptionParser.new do |parser|
  parser.on("--run") { options[:run] = true }
  parser.on("--rejudge") { options[:rejudge] = true }
  parser.on("--synthesize N", Integer) { |count| options[:synthesize] = count }
  parser.on("--user ID", Integer) { |id| options[:user] = id }
end.parse!(ARGV)

abort("N must be a positive integer.\n\n#{USAGE}") if options.key?(:synthesize) && !options[:synthesize].positive?
abort("--synthesize needs --user ID.\n\n#{USAGE}") if options[:synthesize] && !options[:user]
abort("No user with id #{options[:user]}.") if options[:synthesize] && !User.exists?(options[:user])

replay = DesignComparisonReplay.new(api_key: ENV["ANTHROPIC_API_KEY"], rejudge: options[:rejudge])

begin
  if options[:synthesize] then replay.synthesize(options[:user], options[:synthesize], run: options.fetch(:run, false))
  elsif options[:run] then replay.run
  else replay.dry_run
  end
rescue DesignComparisonReplay::MissingKey => e
  abort("#{e.message}\n\n#{USAGE}")
end
