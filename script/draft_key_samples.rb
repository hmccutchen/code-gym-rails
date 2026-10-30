# Drafts sections for the key read on the owner's machine; never run it against production (docs/code-notes/script/key_sample_drafts.md).
require "optparse"
require_relative "key_sample_drafts"

USAGE = <<~TEXT.freeze
  bin/rails runner script/draft_key_samples.rb KIND OUT_PATH [--count N] [--language LANGUAGE]
  bin/rails runner script/draft_key_samples.rb code_review OUT_PATH --triage [--count N] [--solver-model MODEL]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/draft_key_samples.rb KIND OUT_PATH [--triage] --run

  KIND        a kind read from drafts: #{KeySampleDrafts::KINDS.map(&:key).join(', ')}; or code_review with --triage
  OUT_PATH    a new file outside the repository, created before any call and written after each kept section;
              it holds answer keys, so delete it after the read
  (no --run)  plan only: drafts, the most calls and a cost bound at the output cap, with no provider call
  --run       draft and judge on the production routes, billed to ANTHROPIC_API_KEY
  --count N   sections to keep, 1 to 10 (default 6: the read needs 5, plus one spare); with --triage 1 to 30 (default 30)
  --triage    code_review only: toy, single-file drafts cycling the three modes, each kept one solved blind by a
              second call and compared with its key in Ruby; the file holds every disagreement and unlocated
              section and one agreement per mode
  --solver-model  the solve's model, one priced in ClaudeService (default #{KeyTriage::DEFAULT_SOLVER_MODEL})
  --language  #{LanguagePrompts::ALL.keys.join(' or ')} (default ruby_rails)

  Run it against a local database, inside a read-only transaction: it writes no day, history or usage row.
TEXT

options = { language: "ruby_rails", run: false, triage: false, solver_model: KeyTriage::DEFAULT_SOLVER_MODEL }
OptionParser.new do |parser|
  parser.on("--run") { options[:run] = true }
  parser.on("--triage") { options[:triage] = true }
  parser.on("--solver-model MODEL", String) { |model| options[:solver_model] = model }
  parser.on("--count N", Integer) { |count| options[:count] = count }
  parser.on("--language NAME", String) { |name| options[:language] = name }
end.parse!(ARGV)

kind_key, path = ARGV
abort(USAGE) if kind_key.blank? || path.blank?
kinds = options[:triage] ? [ KeySampleDrafts::TRIAGE_KIND ] : KeySampleDrafts::KINDS
kind = kinds.find { |candidate| candidate.key == kind_key }
abort("#{kind_key} isn't drafted #{options[:triage] ? 'with --triage' : 'for the key read'}.\n\n#{USAGE}") unless kind
most = options[:triage] ? 30 : 10
options[:count] ||= options[:triage] ? 30 : 6
abort("--count must be 1 to #{most}.\n\n#{USAGE}") unless options[:count].between?(1, most)
abort("--solver-model must be one of #{ClaudeService::PRICE_PER_MILLION.keys.join(', ')}.") unless ClaudeService::PRICE_PER_MILLION.key?(options[:solver_model])
abort("Unknown language #{options[:language]}.\n\n#{USAGE}") unless LanguagePrompts::ALL.key?(options[:language])
api_key = ENV["ANTHROPIC_API_KEY"]
abort("Set ANTHROPIC_API_KEY to a key you own before --run.") if options[:run] && api_key.blank?
begin
  KeySampleDrafts.refuse_production!
  path = KeySampleDrafts.reserve_out_path!(path) if options[:run]
rescue ArgumentError => e
  abort(e.message)
end

usage  = []
service = KeySampleDrafts.service(api_key.presence || "plan-only", usage, solver_model: options[:solver_model])
drafts  = KeySampleDrafts.new(kind: kind, language: options[:language], count: options[:count], service: service, out: $stdout,
                              triage: options[:triage])
if options[:run]
  result = drafts.call(path)
  puts "=== draft_key_samples: #{kind.key}, #{options[:language]} · #{drafts.cost_line(usage)} ==="
  puts "kept #{result.entries.size} of #{options[:count]} · rejected #{result.rejected} · keyless #{result.keyless} · failed #{result.failed.size}"
  result.failed.each { |failure| puts "  #{failure}" }
  puts drafts.summary(result)
  puts "wrote #{path}"
else
  drafts.plan
end
