# Read-only. Counts accounts for the open-signup question in the security
# audit. Prints numbers only, never an email or a name.
#
#   bin/rails runner script/security_audit/account_counts.rb
#   railway run --service web bin/rails runner script/security_audit/account_counts.rb
require_relative "account_count_report"

AccountCountReport.new.report
