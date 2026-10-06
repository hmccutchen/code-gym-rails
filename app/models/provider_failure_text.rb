# One provider failure as a sentence for a person, written at read time so
# the reset is named in their zone and against the clock. The text lives in
# config/locales under provider_failures; each kind has a variant per
# credential (own_key today, trial next), so a new variant adds text and no
# code. Nothing here carries provider text, a status code or a key: the only
# inputs are the kind, the provider's label, the surface and two times.
#
# Surfaces name what did not happen (provider_failures.outcomes) and, where
# the engineer typed something, that it is still there (provider_failures.saved).
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
    @variant     = VARIANTS.include?(variant.to_s) ? variant.to_s : "own_key"
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

  private

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

  # Gone once the reset has passed: "try again after that" would point at a
  # time already behind the reader.
  def next_step
    return if reset_passed?

    entry(:next, default: nil)
  end

  def wait_in_words
    minutes = ((@reset_at - @now) / 60).ceil
    minutes <= 1 ? "a minute" : "#{minutes} minutes"
  end

  def entry(name, default: :own_key, **interpolations)
    fallback = default == :own_key ? I18n.t("provider_failures.#{@kind}.own_key.#{name}", provider: @provider, **interpolations) : default
    I18n.t("provider_failures.#{@kind}.#{@variant}.#{name}", provider: @provider, default: fallback, **interpolations)
  end
end
