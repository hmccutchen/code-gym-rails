class ApiKeysController < ApplicationController
  skip_before_action :require_api_key

  # GET /setup
  def edit; end

  # PATCH /setup
  def update
    key = params[:api_key].to_s.strip

    unless key.start_with?("sk-ant-")
      flash.now[:alert] = "That doesn't look like an Anthropic API key (should start with sk-ant-)."
      render :edit, status: :unprocessable_entity
      return
    end

    current_user.update!(api_key: key)
    redirect_to root_path, notice: "API key saved. You're all set!"
  end
end
