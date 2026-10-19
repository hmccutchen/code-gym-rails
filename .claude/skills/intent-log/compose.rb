#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge the per-person intent files into the one log a teammate reads.
# Each person owns docs/intent/<github-login>.md and appends only to theirs; a
# day with one author composes to exactly what a solo log already looked like.
# Why it is split that way, and why nobody can write anybody else's, is in
# SKILL.md.

require "date"
require "optparse"

options = {dir: "docs/intent", out: "docs/intent-log.md",
           year: Date.today.year, check: false}
OptionParser.new do |opts|
  opts.banner = "usage: compose.rb [options]"
  opts.on("--dir PATH", "per-person files (default: docs/intent)") { options[:dir] = _1 }
  opts.on("--out PATH", "composed log (default: docs/intent-log.md)") { options[:out] = _1 }
  opts.on("--year YEAR", Integer, "year the headings belong to") { options[:year] = _1 }
  opts.on("--check", "exit 1 if the composed log is out of date") { options[:check] = true }
end.parse!

DEFAULT_HEADER = <<~MD
  # Intent log

  What we worked on, day by day, tagged with the PRs it produced. One short list
  a day per person.

  Composed from `docs/intent/` by `compose.rb`; edit your own file there, never
  this one.
MD

Entry = Struct.new(:date, :heading, :author, :display, :text)

# A line that opens its own unit, so a wrapped tail line can be put back
# together before it is read.
OPENER = /\A(?:- |\s*\*\*|\*|[A-Z][A-Za-z ]*:\s*\z)/

def units(block)
  block.each_line.with_object([]) do |line, list|
    line = line.rstrip
    next if line.empty?
    if list.empty? || line.match?(OPENER) then list << +line
    else list.last << " " << line.strip
    end
  end
end

# A backticked span is one token: `#7 dropped` must never break across lines.
def wrap(text, width)
  text.split.join(" ").scan(/`[^`]*`\S*|\S+/).each_with_object([+""]) do |word, lines|
    if lines.last.empty? then lines[-1] = +word
    elsif lines.last.length + 1 + word.length <= width then lines.last << " " << word
    else lines << +word
    end
  end.join("\n")
end

def heading_date(heading, year)
  match = heading.match(/([A-Z][a-z]{2}) +(\d{1,2})/)
  month = Date::ABBR_MONTHNAMES.index(match[1]) if match
  Date.new(year, month, match[2].to_i) if month
end

# A heading names a weekday and a date but never a year, so the year is carried
# forward from the last heading that named one. Without an anchor a log read in
# January dates its whole first year to the new one. See SKILL.md.
def entries_in(path, fallback)
  source = File.read(path)
  key = File.basename(path, ".md")
  display = source[/\A\s*#\s+(.+)$/, 1]&.strip || key
  year = nil

  previous = nil

  source.split(/^## +(.+)$/)[1..].to_a.each_slice(2).filter_map do |heading, text|
    heading = heading.strip
    named = heading[/\b(20\d{2})\b/, 1]&.to_i
    year = named || year || fallback
    date = heading_date(heading, year)
    next unless date

    # A day that goes backwards is either the new year or a misordering, and
    # guessing puts a silently wrong date on it either way.
    if previous && date < previous && named.nil?
      abort "#{path}: '#{heading}' goes back before #{previous}. Name its " \
        "year, as '#{heading}, #{previous.year + 1}', or put it in order."
    end
    previous = date

    Entry.new(date, heading, key, display, text.to_s.strip)
  end
end

def sources(dir)
  Dir.glob(File.join(dir, "*.md")).reject { File.basename(_1).start_with?("_") }.sort
end

# A tail line the whole team should see, without the PR tags it may carry: the
# digest points at an entry rather than accounting for a PR a second time.
def tails(text, label)
  text.split("\n\n").flat_map { units(_1) }.filter_map do |unit|
    next unless unit.start_with?("*#{label}")

    unit.sub(/\A\*#{Regexp.escape(label)}:?\s*/, "").sub(/\*\z/, "")
      .gsub(/`#\d+[^`]*`/, "").squeeze(" ").strip
  end
end

def digest(entries)
  wanted = entries.flat_map { |entry| tails(entry.text, "Could use a hand").map { [entry, _1] } }
  return "" if wanted.empty?

  lines = wanted.sort_by { |entry, _| [-entry.date.to_time.to_i, entry.display] }.map do |entry, text|
    line = "**#{entry.display}**, #{entry.date.strftime("%b %-d")}: #{text}"
    "- " + wrap(line, 77).gsub("\n", "\n  ")
  end
  "## Could use a hand\n\n#{lines.join("\n")}"
end

def day(entries)
  # the longest heading wins, so a range somebody wrote survives the merge
  heading = entries.map(&:heading).max_by { [_1.length, _1] }
  body =
    if entries.one?
      entries.first.text
    else
      entries.sort_by(&:display).map { "### #{_1.display}\n\n#{_1.text}" }.join("\n\n")
    end
  "## #{heading}\n\n#{body}"
end

def compose(dir, year, header)
  entries = sources(dir).flat_map { entries_in(_1, year) }
  days = entries.group_by(&:date).sort.map { |_, group| day(group) }
  [header.strip, digest(entries), *days].reject(&:empty?).join("\n\n") + "\n"
end

abort "no #{options[:dir]}: each person's entries live there" unless Dir.exist?(options[:dir])

header_file = File.join(options[:dir], "_header.md")
header = File.exist?(header_file) ? File.read(header_file) : DEFAULT_HEADER
composed = compose(options[:dir], options[:year], header)

if options[:check]
  current = File.exist?(options[:out]) ? File.read(options[:out]) : nil
  if current == composed
    puts "ok: #{options[:out]} is current"
    exit
  end
  abort "#{options[:out]} is out of date with #{options[:dir]}; run compose.rb"
end

File.write(options[:out], composed)
puts "composed #{options[:out]} from #{sources(options[:dir]).size} file(s)"
