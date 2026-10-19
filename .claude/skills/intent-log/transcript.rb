# frozen_string_literal: true

# The one reader of Claude Code transcripts. extract.rb and intent-stage.rb
# both go through it, so the prompts staged at session end and the ones
# reconstructed later are picked by the same rules.

require "json"
require "set"
require "time"

module Transcript
  # Claude Code marks injected content (skill bodies, image placeholders,
  # caveats) with isMeta, which covers far more than a list of prefixes ever did.
  NOISE_PREFIXES = ["<", "[Request", "This session is being continued"].freeze

  NOISE_EXACT = [
    "continue", "continue from where you left off.", "/compact", "/clear",
    "go", "ok", "yes", "yep", "thanks", "thank you", "push", "merge"
  ].to_set.freeze

  module_function

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

  # Each prompt the person typed, as [local time, text]. The transcript is UTC;
  # local time is what the person lived.
  def prompts(file)
    records = File.foreach(file).filter_map do |line|
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

      [Time.parse(at).localtime, text]
    end
  end
end
