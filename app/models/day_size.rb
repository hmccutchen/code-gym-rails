# A fixed setting returns early so the rule can't reach it, clamped because a stored count may be out of range.
class DaySize
  Decision = Data.define(:count, :reason, :setting, :completion, :gate) do
    def automatic? = setting.nil?

    # Read from the gate, so the brake blocks coverage even when completion alone would also give the floor.
    def brake? = automatic? && gate.reason == :brake

    def diagnostics
      { count: count, reason: reason, setting: setting || User::AUTOMATIC_SECTION_COUNT, completion: completion,
        gate: { count: gate.count, reason: gate.reason, evidence: gate.evidence } }
    end
  end

  def self.for(setting:, completion:, gate:)
    decision = Decision.new(count: setting&.clamp(SectionCount::FLOOR, ExerciseSection::MAX_SECTIONS),
                            reason: :setting, setting: setting, completion: completion, gate: gate)
    return decision if setting

    decision.with(count: [ completion, gate.count ].min.clamp(SectionCount::FLOOR, ExerciseSection::MAX_SECTIONS),
                  reason: automatic_reason(completion, gate))
  end

  # Completion is named whenever it alone gives the same count; the gate and brake only when they lowered it.
  def self.automatic_reason(completion, gate)
    return :completion if completion <= gate.count

    gate.reason == :brake ? :brake : :gate
  end
  private_class_method :automatic_reason
end
