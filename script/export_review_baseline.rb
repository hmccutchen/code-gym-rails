# Reads inside a read-only transaction and writes nothing; see docs/code-notes/script/review_baseline_export.md.
require "optparse"
require_relative "review_baseline_export"

USAGE = <<~TEXT.freeze
  bin/rails runner script/export_review_baseline.rb --user ID [--limit N] > /a/path/outside/the/repo/review_baseline.json

  --user ID   the account whose reviewed answers to export (required). A regrade sends these answers to a
              provider under the runner's own key, so export only an account whose owner has agreed to that.
  --limit N   at most N sections, newest first (default and maximum #{ReviewBaselineExport::MAX_SECTIONS})

  The JSON goes to stdout and holds answers and answer keys, so redirect it to a file outside the repository and
  delete the file when the run that reads it is done. The counts line goes to stderr.
TEXT

options = { limit: ReviewBaselineExport::MAX_SECTIONS }
OptionParser.new do |parser|
  parser.on("--user ID", Integer) { |id| options[:user] = id }
  parser.on("--limit N", Integer) { |count| options[:limit] = count }
end.parse!(ARGV)

abort(USAGE) unless options[:user]
abort("--limit must be 1 to #{ReviewBaselineExport::MAX_SECTIONS}.\n\n#{USAGE}") unless options[:limit].between?(1, ReviewBaselineExport::MAX_SECTIONS)

# Production logs to stdout, which would corrupt the JSON.
Rails.logger = ActiveSupport::Logger.new(IO::NULL)
ActiveRecord::Base.logger = nil

abort("No user with id #{options[:user]}.") unless User.exists?(options[:user])

payload = ReviewBaselineExport.new(user_id: options[:user], limit: options[:limit]).call
$stdout.write(JSON.generate(payload))
$stderr.puts ReviewBaselineExport.summary(payload)
