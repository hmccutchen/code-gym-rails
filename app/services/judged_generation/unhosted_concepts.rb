module JudgedGeneration::UnhostedConcepts
  def self.for(plan, dropped_concepts)
    if plan.practice_schedule
      return dropped_concepts.keys.filter_map do |key|
        assignment = plan.assignments[key]
        { section: key, concept: assignment[:concept], bucket: assignment[:bucket], planned_as: assignment[:reason] } if assignment
      end
    end

    retention     = (plan.due_checks + plan.fourth_due_checks).map(&:concept)
    reinforcement = (plan.reinforcement.to_a + plan.fourth_reinforcement.to_a).map { |entry| entry[:concept] }

    dropped_concepts.filter_map do |key, concept|
      planned_as = "retention" if retention.include?(concept)
      planned_as ||= "reinforcement" if reinforcement.include?(concept)
      { section: key, concept: concept, planned_as: planned_as } if planned_as
    end
  end
end
