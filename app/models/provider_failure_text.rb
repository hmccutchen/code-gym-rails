# Inputs are only kind, provider label, surface and times, so no provider text, status code or key can reach a person.
class ProviderFailureText
  VARIANTS = %w[own_key trial].freeze
  SURFACES = %i[generation regeneration review review_partial duck follow_up alternate critique reference].freeze

  attr_reader :kind

  def initialize(kind, provider:, surface:, failed_at:, zone:, now: Time.current, retry_after: nil, variant: "own_key")
    @kind        = ProviderFailure.kind?(kind) ? kind.to_s : "other"
    @provider    = AiProvider.label(provider)
    @surface     = surface.to_sym
    @failed_at   = failed_at || now
    @zone        = zone
    @now         = now
    @retry_after = retry_after
    @variant     = variant_for_kind(variant)
    @reset_at    = ResetClock.reset_at(@kind, provider: provider, failed_at: @failed_at, retry_after: retry_after)
  end

  # What happened, what is kept, when it lifts, what to do.
  def full
    [ title, saved, reset, next_step ].compact.join(" ")
  end

  # The one line a status area has room for.
  def brief
    [ title, reset || next_step ].compact.join(" ")
  end

  def reset_passed? = @reset_at.present? && @now >= @reset_at

  def self.variant_for(user)
    user.on_trial? ? "trial" : "own_key"
  end

  private

  # A kind only a trial can hit has text only under the trial variant.
  def variant_for_kind(variant)
    return "trial" if ProviderFailure.trial_kind?(@kind)

    VARIANTS.include?(variant.to_s) ? variant.to_s : "own_key"
  end

  def title
    entry(:title, outcome: I18n.t("provider_failures.outcomes.#{@surface}"))
  end

  def saved
    I18n.t("provider_failures.saved.#{@surface}", default: nil)
  end

  def reset
    return if @reset_at.nil?
    return entry(:reset_passed) if reset_passed?

    local = @reset_at.in_time_zone(@zone)
    entry(:reset_at, time: local.strftime("%-l:%M %P"), day: local.strftime("%A"), wait: wait_in_words)
  end

  # Omitted once the reset has passed, since "try again after that" would point at a time already behind the reader.
  def next_step
    return if reset_passed?

    entry(:next, optional: true)
  end

  def wait_in_words
    minutes = ((@reset_at - @now) / 60).ceil
    minutes <= 1 ? "a minute" : "#{minutes} minutes"
  end

  # Falls back to own_key, or to trial for trial-only kinds; a variant stores only the entries that differ.
  def entry(name, optional: false, **interpolations)
    candidates = [ @variant, variant_for_kind("own_key") ].uniq.map { |variant| "provider_failures.#{@kind}.#{variant}.#{name}" }
    key = candidates.find { |candidate| I18n.exists?(candidate) }
    return if key.nil? && optional

    I18n.t(key || candidates.last, provider: @provider, **interpolations)
  end
end
