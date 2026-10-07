# One provider failure as a sentence for a person, written at read time so
# the reset is named in their zone and against the clock. The text lives in
# config/locales under provider_failures; each kind has a variant per
# credential (own_key, and trial where the words differ), so a new variant
# adds text and no code. Nothing here carries provider text, a status code or a key: the only
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

  # Which credential's words a failure gets: a trial account reads the trial
  # variant, an account with its own key the own_key one.
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

  # Gone once the reset has passed: "try again after that" would point at a
  # time already behind the reader.
  def next_step
    return if reset_passed?

    entry(:next, optional: true)
  end

  def wait_in_words
    minutes = ((@reset_at - @now) / 60).ceil
    minutes <= 1 ? "a minute" : "#{minutes} minutes"
  end

  # Every kind has its words under the base variant, own_key, or trial for a
  # kind only a trial can hit; a variant adds only the entries that differ.
  def entry(name, optional: false, **interpolations)
    candidates = [ @variant, variant_for_kind("own_key") ].uniq.map { |variant| "provider_failures.#{@kind}.#{variant}.#{name}" }
    key = candidates.find { |candidate| I18n.exists?(candidate) }
    return if key.nil? && optional

    I18n.t(key || candidates.last, provider: @provider, **interpolations)
  end
end
