# Mints one invite code and prints it once. Only its digest is stored, so a
# lost code is minted again, never recovered.
#
#   bin/rails runner script/mint_invite_code.rb --provider gemini --seats 2 --days 7 --cap 12 --expires 2026-10-31 --label "pilot"
#   bin/rails runner script/mint_invite_code.rb --seats 1 --expires 2026-10-31 --label "teammate"
#
# --provider KEY  the house key the trial runs on; leave out for a plain join code
# --seats N       accounts the code admits (required)
# --expires DATE  last day the code can be redeemed (required)
# --days N        trial length in days (required with --provider)
# --cap N         provider calls per account per day (with --provider)
# --label TEXT    a note for you; never shown to anyone
options = {}
OptionParser.new do |parser|
  parser.on("--provider KEY") { |key| options[:provider] = key }
  parser.on("--seats N", Integer) { |n| options[:seats] = n }
  parser.on("--expires DATE") { |date| options[:expires_at] = Date.parse(date).end_of_day }
  parser.on("--days N", Integer) { |n| options[:trial_days] = n }
  parser.on("--cap N", Integer) { |n| options[:daily_request_cap] = n }
  parser.on("--label TEXT") { |text| options[:label] = text }
end.parse!(ARGV)

usage = File.readlines(__FILE__).grep(/^#   /).join
abort("--seats N and --expires DATE are required.\n\n#{usage}") unless options[:seats] && options[:expires_at]
abort("--days N is required with --provider.\n\n#{usage}") if options[:provider] && !options[:trial_days]

record, code = InviteCode.mint(**options)
kind = record.trial? ? "#{record.trial_days}-day #{AiProvider.label(record.provider)} trial" : "join code"
puts "Invite code ##{record.id} (#{kind}, #{record.seats} seat#{'s' unless record.seats == 1}, redeem by #{record.expires_at.to_date}):"
puts
puts "  #{code.scan(/.{1,4}/).join('-')}"
puts
puts "Shown once. The code is stored as a digest and cannot be recovered."
