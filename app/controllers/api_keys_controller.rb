class ApiKeysController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_api_key

  # GET /setup
  def edit
    redirect_to welcome_path if current_user.first_run?
  end

  # PATCH /setup
  def update
    key = params[:api_key].to_s.strip
    return language_only_update if key.blank?

    provider = AiProvider.detect(key)

    unless provider
      flash.now[:alert] = t("flash.api_keys.unrecognized_key")
      render :edit, status: :unprocessable_content
      return
    end

    attrs = { api_key: key, provider: provider }
    attrs[:language] = params[:language] if User::LANGUAGES.include?(params[:language])

    current_user.update!(attrs)
    redirect_to root_path, notice: t("flash.api_keys.key_saved")
  end

  private

  # The password field is always blank when this page renders (existing keys
  # are never echoed back), so a blank submission means the user only touched
  # the language dropdown -- not that they're clearing their key.
  def language_only_update
    unless current_user.api_key_present?
      flash.now[:alert] = t("flash.application.api_key_needed")
      render :edit, status: :unprocessable_content
      return
    end

    unless User::LANGUAGES.include?(params[:language])
      redirect_to root_path, notice: t("flash.api_keys.no_changes")
      return
    end

    current_user.update!(language: params[:language])
    redirect_to root_path, notice: t("flash.api_keys.preferences_saved")
  end
end
