class ProfileController < ApplicationController
  # Name editing needs a logged-in user but not an API key, so this endpoint
  # stays a clean JSON surface regardless of key state.
  skip_before_action :require_api_key

  # PATCH /profile — inline name autosave (JSON)
  def update
    if current_user.update(profile_params)
      render json: { name: current_user.name }
    else
      render json: { errors: current_user.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(:name).transform_values { |v| v.to_s.strip }
  end
end
