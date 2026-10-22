# Writes judge_solves records only and never changes an exercise; see docs/code-notes/script/design_comparison_replay.md.
USAGE = <<~TEXT.freeze
  bin/rails runner script/replay_design_comparison_solves.rb
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/replay_design_comparison_solves.rb --run [--rejudge]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/replay_design_comparison_solves.rb --synthesize N --user ID

  (no flag)       dry run: counts by week and by user, first and last date, cost bound; no provider call
  --run           judge every stored design comparison not yet replayed, one at a time
  --rejudge       with --run, judge sections already replayed again
  --synthesize N  draft N fresh design comparisons across the rungs and the vocabulary, judge each,
                  and record them as synthetic; --user names the account whose plan the drafts are built from
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

abort(USAGE) if options[:run] && options[:synthesize]
abort("N must be a positive integer.\n\n#{USAGE}") if options.key?(:synthesize) && !options[:synthesize].positive?
abort("--synthesize needs --user ID.\n\n#{USAGE}") if options[:synthesize] && !options[:user]

replay = DesignComparisonReplay.new(api_key: ENV["ANTHROPIC_API_KEY"], rejudge: options[:rejudge])

begin
  if options[:run] then replay.run
  elsif options[:synthesize] then replay.synthesize(options[:user], options[:synthesize])
  else replay.dry_run
  end
rescue DesignComparisonReplay::MissingKey => e
  abort("#{e.message}\n\n#{USAGE}")
end
