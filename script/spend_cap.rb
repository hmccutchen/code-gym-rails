# Design notes: docs/code-notes/script/spend_cap.md
class SpendCap
  Reached = Class.new(StandardError)

  attr_reader :spent

  def initialize(limit, out)
    raise ArgumentError, "The spend cap must be a positive dollar amount" unless limit.is_a?(Numeric) && limit.positive?

    @limit = limit
    @out   = out
    @spent = 0.0
  end

  def check!(bound)
    return if @spent + bound <= @limit

    raise Reached, "the next call could cost up to #{dollars(bound)}, with #{dollars(@spent)} spent of the #{dollars(@limit)} cap"
  end

  def record(cost, purpose)
    @spent += cost
    @out.puts "  #{dollars(@spent)} spent of #{dollars(@limit)} (#{purpose})"
  end

  private

  def dollars(amount) = "$#{format('%.2f', amount)}"
end
