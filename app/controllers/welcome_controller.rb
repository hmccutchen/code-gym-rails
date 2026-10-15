class WelcomeController < ApplicationController
  STARTING_LEVELS = %w[junior mid_level senior].freeze

  skip_before_action :require_provider

  # GET /welcome
  def show
    redirect_to root_path unless current_user.first_run?
  end
end
