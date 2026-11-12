class ApiKeysController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

  helper_method :suggested_kinds, :suggested_level, :suggested_steps, :show_level_suggestions?, :chosen_language

  KEY_SAVES_PER_HOUR       = 10
  KEY_SAVES_PER_HOUR_BY_IP = 30
  RATE_LIMIT_STORE         = LazyCacheStore.new

  # A checked save asks a provider about the key, so both counts bound how many keys one person can test here.
  rate_limit to: KEY_SAVES_PER_HOUR, within: 1.hour, by: -> { current_user.id }, with: -> { key_saves_limited },
             store: RATE_LIMIT_STORE, name: "key_saves_by_account", only: :update, if: :key_pasted?
  rate_limit to: KEY_SAVES_PER_HOUR_BY_IP, within: 1.hour, with: -> { key_saves_limited },
             store: RATE_LIMIT_STORE, name: "key_saves_by_ip", only: :update, if: :key_pasted?

  SAVED_NOTICES = { accepted: "key_saved", refused: "key_saved_check_refused", unanswered: "key_saved_unchecked",
                    skipped: "key_saved_without_check" }.freeze
  SKIP_CHECK = "1"

  # GET /setup
  def edit
    redirect_to welcome_path if current_user.first_run?
  end

  # PATCH /setup
  def update
    return preferences_update unless key_pasted?

    provider = AiProvider.detect(pasted_key)
    return render_key_alert(t("flash.api_keys.unrecognized_key")) unless provider

    result = skip_check? ? AiService.skip_key_check(provider) : AiService.check_key(provider, pasted_key)
    return render_key_alert(key_rejected_text(provider), offer_unchecked_save: true) if result == :rejected

    return redirect_to(login_path, alert: t("flash.application.login_required")) unless store_key(provider)

    redirect_to root_path, notice: t("flash.api_keys.#{SAVED_NOTICES.fetch(result)}", provider: AiProvider.label(provider))
  end

  private

  EDGE_WHITESPACE = /\A[[:space:]]+|[[:space:]]+\z/

  def pasted_key = params[:api_key].to_s.gsub(EDGE_WHITESPACE, "")

  def key_pasted? = pasted_key.present?

  def posted_language = (params[:language] if User::LANGUAGES.include?(params[:language]))

  def chosen_language = posted_language || current_user.language

  # The check can take seconds, so the lock reloads the row: another tab's key is merged, and a deleted account gets none.
  def store_key(provider)
    current_user.with_lock do
      next false if current_user.anonymized?

      current_user.store_api_key(pasted_key, provider: provider)
      current_user.language = posted_language if posted_language
      current_user.save!
    end
  end

  def skip_check? = params[:skip_check] == SKIP_CHECK

  def render_key_alert(message, status: :unprocessable_content, offer_unchecked_save: false)
    @offer_unchecked_save = offer_unchecked_save
    @key_error = message
    flash.now[:alert] = message
    render :edit, status: status
  end

  def key_saves_limited = render_key_alert(t("flash.api_keys.key_saves_limited"), status: :too_many_requests)

  def key_rejected_text(provider)
    ProviderFailureText.new("bad_key", provider: provider, surface: :key_save, failed_at: Time.current,
                            zone: current_user.effective_time_zone).title
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

    language = posted_language
    provider = params[:provider] if current_user.stored_providers.include?(params[:provider])
    return redirect_to root_path, notice: t("flash.api_keys.no_changes") unless language || provider

    current_user.language = language if language
    current_user.use_provider(provider) if provider
    current_user.save!
    redirect_to root_path, notice: t("flash.api_keys.preferences_saved")
  end
end
