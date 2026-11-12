class ApiKeysController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

  helper_method :suggested_kinds, :suggested_level, :suggested_steps, :show_level_suggestions?, :chosen_language

  KEY_SAVES_PER_HOUR       = 10
  KEY_SAVES_PER_HOUR_BY_IP = 30
  RATE_LIMIT_STORE         = LazyCacheStore.new

  # Each save with a key asks a provider about it, so both counts bound how many keys one person can test here.
  rate_limit to: KEY_SAVES_PER_HOUR, within: 1.hour, by: -> { current_user.id }, with: -> { key_saves_limited },
             store: RATE_LIMIT_STORE, name: "key_saves_by_account", only: :update, if: :key_pasted?
  rate_limit to: KEY_SAVES_PER_HOUR_BY_IP, within: 1.hour, with: -> { key_saves_limited },
             store: RATE_LIMIT_STORE, name: "key_saves_by_ip", only: :update, if: :key_pasted?

  SAVED_NOTICES = { accepted: "key_saved", refused: "key_saved_check_refused", unanswered: "key_saved_unchecked" }.freeze

  # GET /setup
  def edit
    redirect_to welcome_path if current_user.first_run?
  end

  # PATCH /setup
  def update
    return preferences_update unless key_pasted?

    provider = AiProvider.detect(pasted_key)
    return render_key_alert(t("flash.api_keys.unrecognized_key")) unless provider

    result = AiProvider.find(provider).new(pasted_key).check_key
    return render_key_alert(key_rejected_text(provider)) if result == :rejected

    current_user.store_api_key(pasted_key, provider: provider)
    current_user.language = chosen_language
    current_user.save!
    redirect_to root_path, notice: t("flash.api_keys.#{SAVED_NOTICES.fetch(result)}", provider: AiProvider.label(provider))
  end

  private

  def pasted_key = params[:api_key].to_s.strip

  def key_pasted? = pasted_key.present?

  def chosen_language = User::LANGUAGES.include?(params[:language]) ? params[:language] : current_user.language

  def render_key_alert(message, status: :unprocessable_content)
    flash.now[:alert] = message
    render :edit, status: status
  end

  def key_saves_limited = render_key_alert(t("flash.api_keys.key_saves_limited"), status: :too_many_requests)

  def key_rejected_text(provider)
    ProviderFailureText.new("bad_key", provider: provider, surface: :key_save, failed_at: Time.current,
                            zone: current_user.effective_time_zone).full
  end

  def suggested_level
    params[:suggested_level] if LevelSuggestion::LADDER.include?(params[:suggested_level])
  end

  def show_level_suggestions? = params[:show] == "level_suggestions"

  def suggested_steps
    rungs = current_user.kind_rungs
    suggested_kinds.filter_map { |kind| LevelSuggestionStep.new(kind: kind, from: rungs[kind], to: suggested_level) }
                   .select(&:one_rung?).to_h { |step| [ step.kind, { from: step.from, to: step.to } ] }
  end

  def suggested_kinds
    return [] unless suggested_level

    ExerciseSection.keys & Array(params[:suggested]).grep(String)
  end

  # Existing keys are never echoed back, so a blank key field means only the other preferences changed.
  def preferences_update
    return render_key_alert(t("flash.application.api_key_needed")) unless current_user.api_key_present?

    language = params[:language] if User::LANGUAGES.include?(params[:language])
    provider = params[:provider] if current_user.stored_providers.include?(params[:provider])
    return redirect_to root_path, notice: t("flash.api_keys.no_changes") unless language || provider

    current_user.language = language if language
    current_user.use_provider(provider) if provider
    current_user.save!
    redirect_to root_path, notice: t("flash.api_keys.preferences_saved")
  end
end
