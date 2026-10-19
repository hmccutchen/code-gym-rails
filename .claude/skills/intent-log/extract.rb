#!/usr/bin/env ruby
# frozen_string_literal: true

# Pull a person's own prompts out of Claude Code transcripts, grouped into work
# blocks. The log records what the human wanted, so only user turns are read.

require "optparse"
require "open3"
require_relative "transcript"

Prompt = Struct.new(:at, :source, :text)

# Every Claude Code project dir for this checkout and its worktrees, by exact
# name: a prefix would also take in code-gym-rails-api beside code-gym-rails.
def project_dirs(repo)
  listing = begin
    Open3.capture2("git", "-C", repo, "worktree", "list", "--porcelain", err: File::NULL).first
  rescue SystemCallError
    ""
  end
  worktrees = listing.scan(/^worktree (.+)$/).flatten
  names = [File.expand_path(repo), *worktrees].flat_map { [_1.tr("/", "-"), _1.gsub(/[^A-Za-z0-9]/, "-")] }.uniq
  names.map { File.expand_path("~/.claude/projects/#{_1}") }.select { File.directory?(_1) }.sort
end

def prompts_in(file, source)
  Transcript.prompts(file).map { |at, text| Prompt.new(at, source, text) }
end

# A resumed or forked session copies earlier turns, timestamps and all, into
# its own transcript. Those are one prompt; the same words asked again later
# are a second request, and often the one that decided it.
def dedupe(prompts)
  prompts.uniq { [_1.at, _1.text] }
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
