class ApiKeysController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_api_key

  # Gemini keys: Google is transitioning from the legacy "AIza..." format to
  # a new "AQ...." format (rolling out through 2026, with AIza rejected
  # entirely in September 2026) -- accept both during the overlap.
  PROVIDER_PATTERNS = {
    "anthropic" => /\Ask-ant-/,
    "gemini"    => /\A(AIza|AQ\.)/,
    # Project and service-account keys, plus the legacy sk-<random> form. The
    # legacy branch needs alphanumerics straight after "sk-", so it can never
    # match an Anthropic key's "sk-ant-".
    "openai"    => /\Ask-(proj-|svcacct-|[A-Za-z0-9]{20})/
  }.freeze

  # GET /setup
  def edit
    redirect_to welcome_path if current_user.first_run?
  end

  # PATCH /setup
  def update
    key = params[:api_key].to_s.strip
    return language_only_update if key.blank?

    provider = PROVIDER_PATTERNS.find { |_, pattern| key.match?(pattern) }&.first

    unless provider
      flash.now[:alert] = "We don't recognize this key format — currently supporting Anthropic, Gemini and OpenAI keys."
      render :edit, status: :unprocessable_content
      return
    end

    attrs = { api_key: key, provider: provider }
    attrs[:language] = params[:language] if User::LANGUAGES.include?(params[:language])

    current_user.update!(attrs)
    redirect_to root_path, notice: "API key saved. You're all set!"
  end

  private

  # The password field is always blank when this page renders (existing keys
  # are never echoed back), so a blank submission means the user only touched
  # the language dropdown -- not that they're clearing their key.
  def language_only_update
    unless current_user.api_key_present?
      flash.now[:alert] = "Add your API key to get started."
      render :edit, status: :unprocessable_content
      return
    end

    unless User::LANGUAGES.include?(params[:language])
      redirect_to root_path, notice: "No changes made."
      return
    end

    current_user.update!(language: params[:language])
    redirect_to root_path, notice: "Preferences saved!"
  end
end
