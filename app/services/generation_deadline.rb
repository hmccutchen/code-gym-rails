# Design notes: docs/code-notes/app/services/generation_deadline.md
class GenerationDeadline
  attr_reader :ends_at

  def initialize(ends_at, clock: -> { Time.current })
    @ends_at = ends_at
    @clock   = clock
  end

  def ensure_fits!(request)
    return if @ends_at.nil? || @clock.call + request.worst_case_seconds <= @ends_at

    raise ProviderError::DeadlineError, request.purpose
  end

  def leaving(seconds)
    @ends_at.nil? ? self : self.class.new(@ends_at - seconds, clock: @clock)
  end

  NONE = new(nil)
end
