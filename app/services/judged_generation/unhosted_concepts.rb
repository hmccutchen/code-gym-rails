# What the plan asked for that no delivered section carries. The plan
# attributes a concept to a section only in the fourth slot, so this is
# decided after the fact the way AiService#log_retention decides honored:
# the dropped section's own concept, matched against what the plan offered.
# Pure; specs need no database.
module JudgedGeneration::UnhostedConcepts
  def self.for(plan, dropped_concepts)
    retention     = (plan.due_checks + plan.fourth_due_checks).map(&:concept)
    reinforcement = (plan.reinforcement.to_a + plan.fourth_reinforcement.to_a).map { |entry| entry[:concept] }

    dropped_concepts.filter_map do |key, concept|
      planned_as = "retention" if retention.include?(concept)
      planned_as ||= "reinforcement" if reinforcement.include?(concept)
      { section: key, concept: concept, planned_as: planned_as } if planned_as
    end
  end
end
