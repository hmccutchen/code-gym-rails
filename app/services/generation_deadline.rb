# Design notes: docs/code-notes/app/services/generation_deadline.md
class GenerationDeadline
  attr_reader :ends_at

  def initialize(ends_at, clock: -> { Time.current })
    @ends_at = ends_at
    @clock   = clock
  end

  def ensure_fits!(purpose)
    return if @ends_at.nil? || @clock.call + AiService.worst_case_seconds_for(purpose) <= @ends_at

    raise AiService::DeadlineError, purpose
  end

  NONE = new(nil)
end
