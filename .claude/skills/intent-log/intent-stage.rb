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
require "time"
require "fileutils"

# Claude Code marks injected content (skill bodies, image placeholders, caveats)
# with isMeta, which covers far more than a list of prefixes ever did.
NOISE_PREFIXES = ["<", "[Request", "This session is being continued"].freeze

NOISE_EXACT = [
  "continue", "continue from where you left off.", "/compact", "/clear",
  "go", "ok", "yes", "yep", "thanks", "thank you", "push", "merge"
].freeze

def message_text(content)
  case content
  when String then content
  when Array then content.filter_map { _1["text"] if _1.is_a?(Hash) && _1["type"] == "text" }.join(" ")
  end
end

# A prompt typed while the model is working is not a user turn. It lands as a
# queued_command attachment, and only the ones the turn did not absorb come
# back later as a turn of their own; see SKILL.md.
def human_turn(record)
  case record["type"]
  when "user"
    return if record["isMeta"] || record["timestamp"].nil?

    [record["timestamp"], message_text(record.dig("message", "content")), false]
  when "attachment"
    queued = record["attachment"] || {}
    return unless queued["type"] == "queued_command" && queued.dig("origin", "kind") == "human"

    [queued["timestamp"], message_text(queued["prompt"]), true]
  end
end

def prompts_in(transcript)
  records = File.foreach(transcript).filter_map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
  turns = records.filter_map { human_turn(_1) }
  # A queued prompt the turn did not absorb is delivered again as a user turn.
  delivered = turns.filter_map { |_, text, queued| text&.strip unless queued }.to_set

  turns.filter_map do |at, text, queued|
    text = text&.strip
    next if text.nil? || text.length < 4 || at.nil?
    next if queued && delivered.include?(text)
    next if NOISE_PREFIXES.any? { text.start_with?(_1) } || NOISE_EXACT.include?(text.downcase)

    {"at" => Time.parse(at).localtime.iso8601, "text" => text}
  end
end

begin
  event = JSON.parse($stdin.read)
  transcript = event["transcript_path"]
  root = event["cwd"] || Dir.pwd
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
