#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook: refuse to finish while the log is days behind the staging.
#
# Staging runs itself and the write-up does not, so the log lapses without
# anything saying so: this one ran from 2026-08-18 to 2026-09-03, 62 PRs, while
# the hook beside it staged every day perfectly. Nothing noticed because
# nothing was looking. This looks.
#
# It hands the days back rather than reporting them to nobody, and it does that
# at most once a day, marking the attempt before it makes it so a session that
# ignores it is not asked twice.
#
# Never fails a session on its own account: no staging, no log, no git, an
# unreadable anything — all of those exit 0. See SKILL.md.

require "json"
require "date"

BEHIND = Integer(ENV["INTENT_NAG_DAYS"], exception: false) || 3

def heading_date(heading, year)
  match = heading.match(/([A-Z][a-z]{2}) +(\d{1,2})/)
  month = Date::ABBR_MONTHNAMES.index(match[1]) if match
  Date.new(year, month, match[2].to_i) if month
end

# The newest day the log already accounts for. A range heading is read at its
# last date, which is the one that says how far the log has got.
def logged_through(path)
  return nil unless path && File.exist?(path)

  year = nil
  File.read(path).scan(/^## +(.+)$/).flatten.filter_map do |heading|
    year = heading[/\b(20\d{2})\b/, 1]&.to_i || year || Date.today.year
    heading.scan(/[A-Z][a-z]{2} +\d{1,2}/).filter_map { heading_date(_1, year) }.max
  end.max
end

# Whose entries to read. A team file is per person, so somebody else logging
# today must not answer for you.
#
# Only the network answer is cached, and it loses to anything said outright:
# caching what INTENT_AUTHOR asked for once left the name of whoever ran first
# on disk, and every later session in that checkout was judged as them.
def author(root)
  said = ENV["INTENT_AUTHOR"].to_s.strip
  return said unless said.empty?

  cache = File.join(root, ".intent", "author")
  cached = File.read(cache).strip if File.exist?(cache)
  return cached if cached && !cached.empty?

  login = `gh api user -q .login 2>/dev/null`.to_s.strip
  return nil if login.empty?

  File.write(cache, "#{login}\n") rescue nil
  login
end

begin
  root = JSON.parse($stdin.read)["cwd"] rescue nil
  root ||= Dir.pwd

  staged = Dir.glob(File.join(root, ".intent", "staging", "*.jsonl"))
    .filter_map { Date.parse(File.basename(_1, ".jsonl")) rescue nil }
  exit 0 if staged.empty?

  mine = author(root)
  team = File.directory?(File.join(root, "docs", "intent"))
  own = mine && File.join(root, "docs", "intent", "#{mine}.md")
  composed = File.join(root, "docs", "intent-log.md")
  # a repo that keeps no log is not one to nag about
  exit 0 unless team || File.exist?(composed)

  through = logged_through(own) || logged_through(composed)
  behind = staged.select { (through.nil? || _1 > through) && _1 < Date.today }
  exit 0 if behind.size < BEHIND

  marker = File.join(root, ".intent", ".nagged")
  today = Date.today.to_s
  exit 0 if File.exist?(marker) && File.read(marker).strip == today

  File.write(marker, "#{today}\n")

  days = behind.sort
  span = "#{days.first.strftime("%b %-d")} to #{days.last.strftime("%b %-d")}"
  # where a team keeps entries is one file per person, and the composed log is
  # generated, so somebody with no file yet is sent to make theirs rather than
  # to edit the one a commit would refuse anyway
  where = mine && team ? "docs/intent/#{mine}.md" : "docs/intent-log.md"
  warn <<~TEXT
    The intent log is #{days.size} days behind: #{span} are staged and
    unwritten. Write them from .intent/staging/ into
    #{where}, with the intent-log skill, then finish.

    If now is the wrong moment, say so and stop. This will not ask again today.
  TEXT
  exit 2
rescue StandardError
  # a nag is a convenience, never a reason to fail a session
end

exit 0
