# Reads inside a read-only transaction and writes nothing; see docs/code-notes/script/review_baseline_export.md.
require "optparse"
require_relative "review_baseline_export"
require_relative "key_sheet_export"

USAGE = <<~TEXT.freeze
  bin/rails runner script/export_review_baseline.rb --user ID [--per-kind N] [--key-sheet] > /a/path/outside/the/repo/review_baseline.json

  --user ID     the account whose reviewed answers to export (required). A regrade sends these answers to a
                provider under the runner's own key, so export only an account whose owner has agreed to that.
  --per-kind N  at most N sections of each kind, newest first (default and maximum #{ReviewBaselineExport::PER_KIND})
  --key-sheet   instead, the key sheet for reading planted keys: each reviewed keyed section's scenario, question,
                the code or plan it shows, and its answer_key, with no answer, rating, review or date. It is its
                own export and needs its own approval.

  The JSON goes to stdout and holds answers and answer keys, so redirect it to a file outside the repository and
  delete the file when the run that reads it is done. The counts line goes to stderr.
TEXT

options = { per_kind: ReviewBaselineExport::PER_KIND, key_sheet: false }
OptionParser.new do |parser|
  parser.on("--user ID", Integer) { |id| options[:user] = id }
  parser.on("--per-kind N", Integer) { |count| options[:per_kind] = count }
  parser.on("--key-sheet") { options[:key_sheet] = true }
end.parse!(ARGV)

abort(USAGE) unless options[:user]
abort("--per-kind must be 1 to #{ReviewBaselineExport::PER_KIND}.\n\n#{USAGE}") unless options[:per_kind].between?(1, ReviewBaselineExport::PER_KIND)

# Production logs to stdout, which would corrupt the JSON.
Rails.logger = ActiveSupport::Logger.new(IO::NULL)
ActiveRecord::Base.logger = nil

abort("No user with id #{options[:user]}.") unless User.exists?(options[:user])

if options[:key_sheet]
  sheet = KeySheetExport.new(user_id: options[:user], per_kind: options[:per_kind]).call
  $stdout.write(JSON.generate(sheet))
  $stderr.puts "key sheet: #{sheet['sections'].map { |entry| entry['kind'] }.tally.sort.map { |kind, count| "#{kind} #{count}" }.join(', ').presence || 'no keyed sections'}"
else
  payload = ReviewBaselineExport.new(user_id: options[:user], per_kind: options[:per_kind]).call
  $stdout.write(JSON.generate(payload))
  $stderr.puts ReviewBaselineExport.summary(payload)
end
