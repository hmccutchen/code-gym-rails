module UsageHelper
  def usage_dollars(amount)
    return "< $0.01" if amount.positive? && amount < BigDecimal("0.01")
    number_to_currency(amount, precision: 2)
  end
end
