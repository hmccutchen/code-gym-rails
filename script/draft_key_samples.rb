# Drafts sections for the key read on the owner's machine; never run it against production (docs/code-notes/script/key_sample_drafts.md).
require "optparse"
require_relative "key_sample_drafts"

USAGE = <<~TEXT.freeze
  bin/rails runner script/draft_key_samples.rb KIND OUT_PATH [--count N] [--language LANGUAGE]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/draft_key_samples.rb KIND OUT_PATH --run

  KIND        a kind that plants a key: #{ExerciseSection.all.select(&:planted_key?).map(&:key).join(', ')}
  OUT_PATH    a new file outside the repository; it holds answer keys, so delete it after the read
  (no --run)  plan only: drafts, the most calls and an upper-bound cost, with no provider call
  --run       draft and judge on the production routes, billed to ANTHROPIC_API_KEY
  --count N   sections to keep, 1 to 10 (default 6: the read needs 5, plus one spare)
  --language  #{LanguagePrompts::ALL.keys.join(' or ')} (default ruby_rails)

  Run it against a local database. It writes no day, history or usage row there.
TEXT

options = { count: 6, language: "ruby_rails", run: false }
OptionParser.new do |parser|
  parser.on("--run") { options[:run] = true }
  parser.on("--count N", Integer) { |count| options[:count] = count }
  parser.on("--language NAME", String) { |name| options[:language] = name }
end.parse!(ARGV)

kind_key, path = ARGV
abort(USAGE) if kind_key.blank? || path.blank?
kind = ExerciseSection.find(kind_key)
abort("#{kind_key} plants no key.\n\n#{USAGE}") unless kind&.planted_key?
abort("--count must be 1 to 10.\n\n#{USAGE}") unless options[:count].between?(1, 10)
abort("Unknown language #{options[:language]}.\n\n#{USAGE}") unless LanguagePrompts::ALL.key?(options[:language])
begin
  KeySampleDrafts.check_out_path!(path)
rescue ArgumentError => e
  abort(e.message)
end
api_key = ENV["ANTHROPIC_API_KEY"]
abort("Set ANTHROPIC_API_KEY to a key you own before --run.") if options[:run] && api_key.blank?

usage  = []
drafts = KeySampleDrafts.new(kind: kind, language: options[:language], count: options[:count],
                             service: KeySampleDrafts.service(api_key.presence || "plan-only", usage), out: $stdout)
if options[:run]
  result = drafts.call
  drafts.write(result, path)
  puts "=== draft_key_samples: #{kind.key}, #{options[:language]} · #{drafts.cost_line(usage)} ==="
  puts "kept #{result.entries.size} of #{options[:count]} · rejected #{result.rejected} · keyless #{result.keyless} · failed #{result.failed.size}"
  result.failed.each { |failure| puts "  #{failure}" }
  puts "wrote #{File.expand_path(path)}"
else
  drafts.plan
end
