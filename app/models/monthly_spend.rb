class MonthlySpend
  HIDDEN_DAYS = 3

  attr_reader :providers

  def initialize(totals:, today:)
    @providers = totals
    @today = today
  end

  def priced?
    providers.any?(&:cost_usd)
  end

  def total
    return unless priced?

    providers.filter_map(&:cost_usd).sum
  end

  def projected
    return unless priced? && @today.day > HIDDEN_DAYS

    total / weekdays(@today.beginning_of_month..@today) * weekdays(@today.all_month)
  end

  def unpriced_requests
    providers.sum(&:unpriced_requests)
  end

  def show_unpriced_note?
    priced? && unpriced_requests.positive?
  end

  private

  def weekdays(range)
    range.count(&:on_weekday?)
  end
end
