# Read-only, makes no provider call and prints counts only; see docs/code-notes/script/code_review_split.md.
require "optparse"
require_relative "code_review_split"

USAGE = <<~TEXT.freeze
  bin/rails runner script/split_code_review_results.rb [--log /a/path/outside/the/repo/worker.log]

  Prints reviewed code_review results by shape (single, multi or bug_hunt) and rung, with each rating, read inside a
  read-only transaction. Run it only with the owner's approval of the query.

  --log FILE  also count the multi-file code_review [planted_key] lines in FILE, by outcome. Export the worker's log
              to a file outside the repository, and delete it when the run is done.
TEXT

options = {}
OptionParser.new do |parser|
  parser.on("--log FILE") { |path| options[:log] = path }
  parser.on("-h", "--help") { abort(USAGE) }
end.parse!(ARGV)

abort("No log file at #{options[:log]}.\n\n#{USAGE}") if options[:log] && !File.file?(options[:log])

CodeReviewSplit.new(log_lines: options[:log] && File.foreach(options[:log]).map(&:chomp)).report
