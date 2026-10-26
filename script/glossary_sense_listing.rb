# Read-only: bin/rails runner script/glossary_sense_listing.rb <export.jsonl> <base_words.txt> lists each match of a new spelling; the export (one JSON object per line with source, id, field, text) and the base words (every key and form, one per line) are the operator's; add --words to print the current words, and run that at the base commit to make the file.
require_relative "glossary_sense_listing_report"

if ARGV == [ "--words" ]
  puts GlossarySenseListingReport.words_in
  exit
end

abort("Usage: bin/rails runner script/glossary_sense_listing.rb <export.jsonl> <base_words.txt> | --words") if ARGV.size != 2 || !ARGV.all? { |path| File.file?(path) && File.readable?(path) }

export_path, base_words_path = ARGV
GlossarySenseListingReport.new(GlossarySenseListingReport.read_rows(export_path), base_words: GlossarySenseListingReport.read_words(base_words_path)).print
