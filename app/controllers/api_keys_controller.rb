class ApiKeysController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

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

  # The password field is always blank when this page renders (existing keys
  # are never echoed back), so a blank submission means the user only touched
  # the language dropdown or the provider choice -- not that they're clearing
  # their key.
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
