# Usage: bin/rails runner script/report_answer_positions.rb
# Read-only: prints how often the better design-comparison piece was shown as A
# and as B across every stored exercise. Makes no provider call.
require_relative "answer_position_balance"

AnswerPositionBalance.new.report
