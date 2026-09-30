class WelcomeController < ApplicationController
  skip_before_action :require_api_key

  # GET /welcome
  def show
    redirect_to root_path unless current_user.first_run?
  end
end
