# Read-only. Usage: bin/rails runner script/security_audit/parameter_filter_check.rb
require_relative "parameter_filter_report"

ParameterFilterReport.new.report
