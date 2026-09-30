# Coverage uses an unsaved mixed user so operator preferences cannot narrow
# the pool. Refreshing a gap rewrites the shared reference and guide too.
class JuniorLadderPreparation
  def initialize(operator_id:, out: $stdout)
    @operator_id = operator_id
    @out = out
  end

  def gaps
    coverage.gaps_for(ExerciseSection.all)
  end

  def report
    ExerciseSection.all.each do |kind|
      entry = coverage.for_kind(kind)
      @out.puts format("%-20s %3d/%3d grounded", kind.key, entry.grounded.size, entry.pairs.size)
    end
    @out.puts "#{gaps.size} pairs without a ladder"
    @out.puts "With --run, generation is billed to user #{@operator_id} using their API key."
    @out.puts "Each refresh rewrites the whole shared reference and guide wording for every user."
  end

  def run!
    operator = User.active.find(@operator_id)
    raise ArgumentError, "User #{@operator_id} has no API key to bill" unless operator.api_key_present?

    gaps.each do |concept, bucket|
      GenerateConceptReferenceJob.perform_later(concept: concept, language: bucket, user_id: operator.id, refresh: true)
    end
    @out.puts "Queued #{gaps.size} jobs, billed to user #{operator.id}"
  end

  private

  def coverage
    @coverage ||= LadderCoverage.for(User.new(language: "mixed"))
  end
end
