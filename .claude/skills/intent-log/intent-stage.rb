#!/usr/bin/env ruby
# frozen_string_literal: true

# SessionEnd hook: stage this session's own prompts for the intent log.
#
# Reconstructing intent weeks later is lossy, so each session drops its prompts
# into .intent/staging/<date>.jsonl while they are fresh and /intent-log writes
# the day's paragraph from them. Only user turns are read, never the assistant's.
#
# Never blocks and never fails a session: any error exits 0 silently.

require "json"
require "set"
require "fileutils"
require_relative "transcript"

def prompts_in(transcript)
  Transcript.prompts(transcript).map { |at, text| {"at" => at.iso8601, "text" => text} }
end

begin
  event = JSON.parse($stdin.read)
  transcript = event["transcript_path"]
  root = ENV["CLAUDE_PROJECT_DIR"] || event["cwd"] || Dir.pwd
  exit 0 unless transcript && File.file?(transcript)

  staging = File.join(root, ".intent", "staging")
  FileUtils.mkdir_p(staging)

  prompts_in(transcript).group_by { _1["at"][0, 10] }.each do |day, prompts|
    file = File.join(staging, "#{day}.jsonl")
    seen = File.exist?(file) ? File.readlines(file).map(&:strip).to_set : Set.new
    fresh = prompts.map { JSON.generate(_1.merge("session" => event["session_id"])) }.reject { seen.include?(_1) }
    File.open(file, "a") { |f| fresh.each { |line| f.puts(line) } } if fresh.any?
  end
rescue StandardError
  # staging is a convenience, never a reason to fail a session
end

exit 0
