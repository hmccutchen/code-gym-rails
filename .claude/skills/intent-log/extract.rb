#!/usr/bin/env ruby
# frozen_string_literal: true

# Pull a person's own prompts out of Claude Code transcripts, grouped into work
# blocks. The log records what the human wanted, so only user turns are read.

require "json"
require "set"
require "time"
require "optparse"

# Claude Code marks injected content (skill bodies, image placeholders, caveats)
# with isMeta, which covers far more than a list of prefixes ever did.
NOISE_PREFIXES = ["<", "[Request", "This session is being continued"].freeze

NOISE_EXACT = [
  "continue", "continue from where you left off.", "/compact", "/clear",
  "go", "ok", "yes", "yep", "thanks", "thank you", "push", "merge"
].to_set

Prompt = Struct.new(:at, :source, :text)

# Every Claude Code project dir for this repo, worktrees included.
def project_dirs(repo)
  encoded = File.expand_path(repo).tr("/", "-")
  Dir.glob(File.expand_path("~/.claude/projects/#{encoded}*")).select { File.directory?(_1) }.sort
end

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

def prompts_in(file, source)
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

    # the transcript is UTC; local time is what the person lived
    Prompt.new(Time.parse(at).localtime, source, text)
  end
end

# Parallel sessions on one day repeat each other's prompts.
def dedupe(prompts)
  seen = {}
  prompts.reject do |prompt|
    key = prompt.text[0, 120]
    repeat = seen[key] && prompt.at - seen[key] < 120
    seen[key] = prompt.at
    repeat
  end
end

def load_prompts(repo)
  dirs = project_dirs(repo)
  prompts = dirs.flat_map do |dir|
    Dir.glob("#{dir}/*.jsonl").flat_map { prompts_in(_1, File.basename(dir)) }
  end
  [dedupe(prompts.sort_by(&:at)), dirs]
end

# A work block breaks on a long idle gap, never at midnight.
def work_blocks(prompts, gap_hours)
  prompts.slice_when { |before, after| after.at - before.at > gap_hours * 3600 }.to_a
end

options = {repo: Dir.pwd, gap: 5.0, cap: 400}
parser = OptionParser.new do |opts|
  opts.banner = "usage: extract.rb {blocks|dump|sources} [YYYY-MM-DD[..YYYY-MM-DD]] [options]"
  opts.on("--repo PATH", "repo to read prompts for (default: cwd)") { options[:repo] = _1 }
  opts.on("--gap HOURS", Float, "idle hours that end a work block (default: 5)") { options[:gap] = _1 }
  opts.on("--cap CHARS", Integer, "max chars per prompt when dumping (default: 400)") { options[:cap] = _1 }
end
parser.parse!

mode = ARGV.shift
abort parser.banner unless %w[blocks dump sources].include?(mode)
low, high = ARGV.shift.to_s.split("..")
high ||= low

prompts, dirs = load_prompts(options[:repo])
abort "no prompts found for #{options[:repo]} (looked in #{dirs.size} project dirs)" if prompts.empty?

if mode == "sources"
  puts "#{prompts.size} prompts across #{dirs.size} project dirs:"
  dirs.each { puts "  #{File.basename(_1)}" }
  exit
end

in_range = lambda do |time|
  day = time.strftime("%Y-%m-%d")
  (low.nil? || day >= low) && (high.nil? || day <= high)
end

work_blocks(prompts, options[:gap]).each do |block|
  next unless in_range.call(block.first.at)

  span = "#{block.first.at.strftime("%a %Y-%m-%d %H:%M")} -> #{block.last.at.strftime("%a %m-%d %H:%M")}"
  if mode == "blocks"
    worktree = "  [+worktree]" if block.map(&:source).uniq.size > 1
    puts format("%s  prompts=%3d%s", span, block.size, worktree)
  else
    puts "\n===== work block #{span} ====="
    block.each { puts "#{_1.at.strftime("%m-%d %H:%M")}\t#{_1.text[0, options[:cap]].gsub("\n", " / ")}" }
  end
end
