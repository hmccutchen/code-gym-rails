# Reads inside a read-only transaction and writes nothing; see docs/code-notes/script/glossary_text_export.md.
require_relative "glossary_text_export"

USAGE = <<~TEXT.freeze
  bin/rails runner script/export_glossary_text.rb > /a/path/outside/the/repo/glossary_text.jsonl

  Writes every stored piece of text the pages run through glossary_wrap, one JSON object per line with source,
  id, field and text: each reviewed section's review points, difficulty reason and saved alternate
  explanations, and each exercise section's scenario, question, options, request and problem statement.
  Feed the file to script/glossary_sense_listing.rb. It holds generated review and exercise text but no
  answers, ratings or user details, so keep it outside the repository and delete it when the listing is read.
TEXT

abort(USAGE) unless ARGV.empty?

GlossaryTextExport.new(out: $stdout).call
