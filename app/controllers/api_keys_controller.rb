class ApiKeysController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

  helper_method :suggested_kinds, :suggested_level, :suggested_steps, :show_level_suggestions?

  # GET /setup
  def edit
    redirect_to welcome_path if current_user.first_run?
  end

  # PATCH /setup
  def update
    key = params[:api_key].to_s.strip
    return preferences_update if key.blank?

    provider = AiProvider.detect(key)

    unless provider
      flash.now[:alert] = t("flash.api_keys.unrecognized_key")
      render :edit, status: :unprocessable_content
      return
    end

    current_user.store_api_key(key, provider: provider)
    current_user.language = params[:language] if User::LANGUAGES.include?(params[:language])
    current_user.save!
    redirect_to root_path, notice: t("flash.api_keys.key_saved")
  end

  private

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
    unless current_user.api_key_present?
      flash.now[:alert] = t("flash.application.api_key_needed")
      render :edit, status: :unprocessable_content
      return
    end

    attrs = {}
    attrs[:language] = params[:language] if User::LANGUAGES.include?(params[:language])
    attrs[:provider] = params[:provider] if current_user.stored_providers.include?(params[:provider])
    return redirect_to root_path, notice: t("flash.api_keys.no_changes") if attrs.empty?

    current_user.update!(attrs)
    redirect_to root_path, notice: t("flash.api_keys.preferences_saved")
  end
end
