# Read-only: bin/rails runner script/glossary_sense_listing.rb <export.jsonl> <base_keys.txt> lists each new glossary match; the export (one JSON object per line with source, id, field, text) and the base keys (one per line, from main) are the operator's.
require_relative "glossary_sense_listing_report"

abort("Usage: bin/rails runner script/glossary_sense_listing.rb <export.jsonl> <base_keys.txt>") if ARGV.size != 2 || !ARGV.all? { |path| File.file?(path) && File.readable?(path) }

export_path, base_keys_path = ARGV
GlossarySenseListingReport.new(GlossarySenseListingReport.read_rows(export_path), base_words: GlossarySenseListingReport.read_words(base_keys_path)).print
