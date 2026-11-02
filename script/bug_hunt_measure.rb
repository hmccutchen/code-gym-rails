# Builds and reports the bug_hunt measurement; it never runs drafted code (docs/code-notes/script/bug_hunt_measure.md).
require "optparse"
require_relative "bug_hunt_measure/build"
require_relative "bug_hunt_measure/report"

USAGE = <<~TEXT.freeze
  bin/rails runner script/bug_hunt_measure.rb build DRAFTS_PATH [DRAFTS_PATH] HARNESS_DIR
  bin/rails runner script/bug_hunt_measure.rb report HARNESS_DIR RESULTS_PATH [RESULTS_PATH] OUT_DIR [--seed N]

  build    reads the drafts file(s) from draft_key_samples.rb --mode bug_hunt and writes HARNESS_DIR (harness files,
           harnesses.txt, build_id, run.sh, manifest.json) and HARNESS_DIR.tar.gz (the same without manifest.json), both
           outside the repository; it prints the archive's SHA-256 and runs nothing
  report   reads HARNESS_DIR/manifest.json and the results file(s) run.sh wrote, refuses results from another build or
           runtime, or with a harness missing, repeated or outside the format, and writes OUT_DIR/failures.md and
           OUT_DIR/counts.txt outside the repository; --seed repeats the passing sample's pick

  Every file it reads or writes holds answer keys: delete them all after the read.
TEXT

seed = nil
OptionParser.new { |parser| parser.on("--seed N", Integer) { |value| seed = value } }.parse!(ARGV)
command, *paths = ARGV

begin
  case command
  when "build"
    abort(USAGE) unless paths.size >= 2
    built = BugHuntMeasure::Build.new(paths[0..-2], paths.last).call
    puts "wrote #{built[:harnesses]} harnesses for #{built[:drafts]} drafts to #{built[:dir]}"
    puts "archive #{built[:archive]} · sha256 #{built[:sha256]}"
  when "report"
    abort(USAGE) unless paths.size >= 3
    report = BugHuntMeasure::Report.new(paths.first, paths[1..-2], paths.last, **{ seed: seed }.compact)
    puts report.call
    puts "wrote #{File.join(paths.last, 'failures.md')} and counts.txt"
  else
    abort(USAGE)
  end
rescue ArgumentError, BugHuntMeasure::Report::Refused => e
  abort(e.message)
end
