# frozen_string_literal: true

# The one reader of Claude Code transcripts. extract.rb and intent-stage.rb
# both go through it, so the prompts staged at session end and the ones
# reconstructed later are picked by the same rules.

require "json"
require "set"
require "time"

module Transcript
  # Claude Code marks most injected content with isMeta. These tags arrive as
  # user turns without it; any other leading markup is the person's, a paste or
  # a snippet of HTML they typed.
  HARNESS_TAG = /\A<(?:task-notification|command-|local-command-|bash-|system-reminder)/
  NOISE_PREFIXES = ["[Request", "This session is being continued"].freeze

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

  # A queued prompt the turn did not absorb is delivered again as a user turn,
  # and only a delivery after it can be that: the same words asked earlier, or
  # asked again later, are separate requests. Each delivery settles one queue.
  def redelivered_queues(turns)
    waiting = Hash.new { |h, k| h[k] = [] }
    turns.each_with_index.with_object(Set.new) do |((_, text, queued), index), settled|
      if queued then waiting[text] << index
      elsif waiting[text].any? then settled << waiting[text].pop
      end
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
    turns = records.filter_map { human_turn(_1) }.map { |at, text, queued| [at, text&.strip, queued] }
    redelivered = redelivered_queues(turns)

    turns.each_with_index.filter_map do |(at, text, _), index|
      next if text.nil? || text.length < 4 || at.nil?
      next if redelivered.include?(index)
      next if text.match?(HARNESS_TAG) || NOISE_PREFIXES.any? { text.start_with?(_1) } || NOISE_EXACT.include?(text.downcase)

      [Time.parse(at).localtime, text]
    end
  end
end
