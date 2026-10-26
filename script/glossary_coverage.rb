# Read-only: bin/rails runner script/glossary_coverage.rb <tsv> [<tsv>...] prints how much of an audit the glossary covers.
require_relative "glossary_coverage_report"

abort("Usage: bin/rails runner script/glossary_coverage.rb <tsv> [<tsv>...]") if ARGV.empty? || !ARGV.all? { |path| File.file?(path) && File.readable?(path) }

resolver = Glossary.method(:key_for) if Glossary.respond_to?(:key_for)
GlossaryCoverageReport.new(GlossaryCoverageReport.read(ARGV), resolver: resolver).print
