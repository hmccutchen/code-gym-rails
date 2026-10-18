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

  def guard(provider)
    return provider if @ends_at.nil?

    JudgedGeneration::Provider.new(
      judge_section: lambda { |*args, **options|
        ensure_fits!("judge_section")
        provider.judge_section.call(*args, **options)
      },
      retry_section: lambda { |*args|
        ensure_fits!("retry_section")
        provider.retry_section.call(*args)
      }
    )
  end

  NONE = new(nil)
end
