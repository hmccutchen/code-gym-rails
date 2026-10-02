# How many sections a day is planned with, before any coverage addition.
# Pure: the Daily sections setting, SectionCount's completion count and the
# CompetencyGate's Plan in, a Decision out.
#
# A fixed setting is an early return rather than a bound fed through the
# rule below, so no change to that rule can reach a user who chose a count.
class DaySize
  Decision = Data.define(:count, :reason, :setting, :completion, :gate) do
    def automatic? = setting.nil?

    # Read from the gate rather than from which bound decided: while the
    # too-hard results stay in the window the day gains no coverage section,
    # even when completion alone would also have given the floor.
    def brake? = automatic? && gate.reason == :brake

    def diagnostics
      { count: count, reason: reason, setting: setting || User::AUTOMATIC_SECTION_COUNT, completion: completion,
        gate: { count: gate.count, reason: gate.reason, evidence: gate.evidence } }
    end
  end

  def self.for(setting:, completion:, gate:)
    decision = Decision.new(count: setting, reason: :setting, setting: setting, completion: completion, gate: gate)
    return decision if setting

    decision.with(count: [ completion, gate.count ].min.clamp(SectionCount::FLOOR, ExerciseSection::MAX_SECTIONS),
                  reason: automatic_reason(completion, gate))
  end

  # Completion names the day whenever it alone would have given the same
  # count, so the gate and the brake are named only when they lowered it.
  def self.automatic_reason(completion, gate)
    return :completion if completion <= gate.count

    gate.reason == :brake ? :brake : :gate
  end
  private_class_method :automatic_reason
end
