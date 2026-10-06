# Read-only. Prints which request parameters the app's own filter_parameters
# masks in request logs and which it lets through.
#
#   bin/rails runner script/security_audit/parameter_filter_check.rb
require_relative "parameter_filter_report"

ParameterFilterReport.new.report
