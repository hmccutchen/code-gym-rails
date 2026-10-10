# Read-only. Usage: bin/rails runner script/security_audit/account_counts.rb (or through railway run).
require_relative "account_count_report"

AccountCountReport.new.report
