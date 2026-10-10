# Prints a new invite code once; only its digest is stored, so a lost code is minted again, never recovered.
USAGE = <<~TEXT.freeze
  bin/rails runner script/mint_invite_code.rb --seats 2 --days 7 --cap 12 --expires 2026-10-31 --label "pilot"

  --seats N       trials the code starts (required)
  --expires DATE  last day the code can be redeemed (required)
  --days N        trial length in days (required)
  --cap N         provider calls per account per day; leave out for no cap
  --label TEXT    a note for you; never shown to anyone
TEXT

require "optparse"

options = {}
OptionParser.new do |parser|
  parser.on("--seats N", Integer) { |n| options[:seats] = n }
  parser.on("--expires DATE") { |date| options[:expires_at] = Date.parse(date).end_of_day }
  parser.on("--days N", Integer) { |n| options[:trial_days] = n }
  parser.on("--cap N", Integer) { |n| options[:daily_request_cap] = n }
  parser.on("--label TEXT") { |text| options[:label] = text }
end.parse!(ARGV)

unless options[:seats] && options[:expires_at] && options[:trial_days]
  abort("--seats N, --days N and --expires DATE are required.\n\n#{USAGE}")
end

record, code = InviteCode.mint(**options)
puts "Invite code ##{record.id} (#{record.trial_days}-day trial, #{record.seats} seat#{'s' unless record.seats == 1}, redeem by #{record.expires_at.to_date}):"
puts
puts "  #{code.scan(/.{1,4}/).join('-')}"
puts
puts "Shown once. The code is stored as a digest and cannot be recovered."
