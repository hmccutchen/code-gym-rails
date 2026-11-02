# Drafts sections for the key read on the owner's machine; never run it against production (docs/code-notes/script/key_sample_drafts.md).
require "optparse"
require_relative "key_sample_drafts"

USAGE = <<~TEXT.freeze
  bin/rails runner script/draft_key_samples.rb KIND OUT_PATH [--count N] [--language LANGUAGE]
  bin/rails runner script/draft_key_samples.rb code_review OUT_PATH --triage [--count N] [--solver-model MODEL]
  bin/rails runner script/draft_key_samples.rb code_review OUT_PATH --mode bug_hunt [--language LANGUAGE] [--entries ID,ID] [--count N]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/draft_key_samples.rb KIND OUT_PATH [--triage] --run --max-cost DOLLARS

  KIND        a kind read from drafts: #{KeySampleDrafts::KINDS.map(&:key).join(', ')}; or code_review, drafted as toy,
              single-file sections cycling the three modes
  OUT_PATH    a new file outside the repository, created before any call and written after each kept section;
              it holds answer keys, so delete it after the read
  (no --run)  plan only: drafts, the most calls and a cost bound at the output cap, with no provider call
  --run       draft and judge on the production routes, billed to ANTHROPIC_API_KEY
  --max-cost DOLLARS  required with --run: before each section and each call, stop if its estimated worst case
              (input at 3 characters a token, plus its full output cap) could take spending past this amount;
              keep what was drafted and print the running cost after each call. A section needs about $0.36 of
              headroom (#{KeyTriage::DEFAULT_SOLVER_MODEL} solve extra with --triage), so the run stops up to that
              much short of the cap. The client's own retries after a 429, 5xx or timeout aren't checked again.
  --count N   sections to keep, 1 to #{KeySampleDrafts::COUNTS[:drafts][:most]} (default #{KeySampleDrafts::COUNTS[:drafts][:default]}: the read needs 5, plus one spare);
              with --triage 1 to #{KeySampleDrafts::COUNTS[:triage][:most]} (default #{KeySampleDrafts::COUNTS[:triage][:default]})
  --triage    code_review only: each kept section solved blind by a second call and compared with its key in Ruby;
              the file holds every disagreement and unlocated section and one agreement per mode
  --mode bug_hunt  code_review only, not with --triage: one kept section per bug_hunt registry entry for the language,
              in list order, each with the entry's trap and concept; --count defaults to the number of entries
  --entries ID,ID  with --mode bug_hunt: draft only these registry entries, in the order given (a partial re-measure)
  --solver-model  the solve's model: #{KeyTriage::SOLVER_MODELS.join(' or ')} (default #{KeyTriage::DEFAULT_SOLVER_MODEL})
  --language  #{LanguagePrompts::ALL.keys.join(' or ')} (default ruby_rails)

  Run it against a local database, inside a read-only transaction: it writes no day, history or usage row.
TEXT

options = { language: "ruby_rails", run: false, triage: false, solver_model: KeyTriage::DEFAULT_SOLVER_MODEL, mode: nil, entries: nil }
OptionParser.new do |parser|
  parser.on("--run") { options[:run] = true }
  parser.on("--triage") { options[:triage] = true }
  parser.on("--solver-model MODEL", String) { |model| options[:solver_model] = model }
  parser.on("--count N", Integer) { |count| options[:count] = count }
  parser.on("--max-cost DOLLARS", Float) { |dollars| options[:max_cost] = dollars }
  parser.on("--language NAME", String) { |name| options[:language] = name }
  parser.on("--mode MODE", String) { |mode| options[:mode] = mode }
  parser.on("--entries IDS", Array) { |ids| options[:entries] = ids }
end.parse!(ARGV)

kind_key, path = ARGV
abort(USAGE) if kind_key.blank? || path.blank?
kinds = options[:triage] ? [ KeySampleDrafts::TRIAGE_KIND ] : [ *KeySampleDrafts::KINDS, KeySampleDrafts::TRIAGE_KIND ]
kind = kinds.find { |candidate| candidate.key == kind_key }
abort("#{kind_key} isn't drafted #{options[:triage] ? 'with --triage' : 'for the key read'}.\n\n#{USAGE}") unless kind
abort("Unknown language #{options[:language]}.\n\n#{USAGE}") unless LanguagePrompts::ALL.key?(options[:language])
abort("--mode takes bug_hunt only.\n\n#{USAGE}") unless options[:mode].nil? || options[:mode] == "bug_hunt"
bug_hunt = options[:mode] == "bug_hunt"
if bug_hunt
  begin
    options[:count] ||= KeySampleDrafts.gotchas_for(options[:language], options[:entries]).size
  rescue ArgumentError, ConceptVocabulary::UnknownLanguage => e
    abort("#{e.message}\n\n#{USAGE}")
  end
else
  counts = KeySampleDrafts::COUNTS.fetch(options[:triage] ? :triage : :drafts)
  options[:count] ||= counts[:default]
  abort("--count must be 1 to #{counts[:most]}.\n\n#{USAGE}") unless options[:count].between?(1, counts[:most])
end
api_key = ENV["ANTHROPIC_API_KEY"]
abort("Set ANTHROPIC_API_KEY to a key you own before --run.") if options[:run] && api_key.blank?
abort("Pass --max-cost DOLLARS with --run.\n\n#{USAGE}") if options[:run] && options[:max_cost].nil?
begin
  KeySampleDrafts.refuse_production!
  usage   = []
  cap     = SpendCap.new(options[:max_cost], $stdout) if options[:max_cost]
  service = KeySampleDrafts.service(api_key.presence || "plan-only", usage, solver_model: options[:solver_model], cap: cap)
  drafts  = KeySampleDrafts.new(kind: kind, language: options[:language], count: options[:count], service: service, out: $stdout,
                                triage: options[:triage], bug_hunt: bug_hunt, entries: options[:entries])
  path    = KeySampleDrafts.reserve_out_path!(path) if options[:run]
rescue ArgumentError => e
  abort(e.message)
end

if options[:run]
  result = drafts.call(path)
  puts "=== draft_key_samples: #{kind.key}, #{options[:language]} · #{drafts.cost_line(usage)} ==="
  puts "kept #{result.entries.size} of #{options[:count]} · rejected #{result.rejected} · keyless #{result.keyless} · failed #{result.failed.size}"
  result.failed.each { |failure| puts "  #{failure}" }
  puts drafts.summary(result)
  puts result.stopped if result.stopped
  puts "wrote #{path}"
else
  drafts.plan
  puts "with --max-cost $#{format('%.2f', options[:max_cost])}, the run stops before any section or call whose estimated worst case could pass it" if options[:max_cost]
end
