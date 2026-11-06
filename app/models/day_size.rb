class DaySize
  Decision = Data.define(:count, :reason, :setting, :gate) do
    def automatic? = setting.nil?

    # Coverage must not bypass either an isolated skip or workload recovery.
    def brake? = automatic? && gate.safety_hold

    def diagnostics
      { count: count, reason: reason, setting: setting || User::AUTOMATIC_SECTION_COUNT,
        gate: gate&.to_h }
    end
  end

  def self.for(setting:, gate: nil)
    return Decision.new(count: setting.clamp(User::DAILY_SECTION_COUNTS), reason: :setting, setting: setting, gate: nil) if setting

    reason = %i[brake completion].include?(gate.reason) ? gate.reason : :gate
    Decision.new(count: gate.count, reason: reason, setting: nil, gate: gate)
  end
end
