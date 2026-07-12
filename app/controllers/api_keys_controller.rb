class ApiKeysController < ApplicationController
  skip_before_action :require_api_key

  PROVIDER_PATTERNS = {
    "anthropic" => /\Ask-ant-/,
    "gemini"    => /\AAIza/
  }.freeze

  # GET /setup
  def edit; end

  # PATCH /setup
  def update
    key      = params[:api_key].to_s.strip
    provider = PROVIDER_PATTERNS.find { |_, pattern| key.match?(pattern) }&.first

    unless provider
      flash.now[:alert] = "We don't recognize this key format — currently supporting Anthropic and Gemini keys."
      render :edit, status: :unprocessable_entity
      return
    end

    current_user.update!(api_key: key, provider: provider)
    redirect_to root_path, notice: "API key saved. You're all set!"
  end
end
