class MonthlySpend
  HIDDEN_DAYS = 3

  attr_reader :providers

  def initialize(totals:, today:, paused: false)
    @providers = totals
    @today = today
    @paused = paused
  end

  def priced?
    providers.any?(&:priced?)
  end

  def total
    return unless priced?

    providers.select(&:priced?).sum(&:cost_usd)
  end

  def projected
    return unless projectable?

    total / weekdays(@today.beginning_of_month..@today) * weekdays(@today.all_month)
  end

  def unpriced_requests
    providers.sum(&:unpriced_requests)
  end

  def show_unpriced_note?
    priced? && unpriced_requests.positive?
  end

  private

  def projectable?
    !@paused && priced? && providers.all?(&:priced?) && @today.day > HIDDEN_DAYS
  end

  def weekdays(range)
    range.count(&:on_weekday?)
  end
end
