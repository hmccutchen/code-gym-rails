class ProfileController < ApplicationController
  # Name editing needs a logged-in user but not an API key, so this endpoint
  # stays a clean JSON surface regardless of key state.
  skip_before_action :require_api_key

  # PATCH /profile — inline name autosave (JSON)
  def update
    if current_user.update(profile_params)
      render json: { name: current_user.name, time_zone: current_user.time_zone,
                     adaptive_set_size: current_user.adaptive_set_size }
    else
      render json: { errors: current_user.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  private

  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :adaptive_set_size)
    permitted[:name] = permitted[:name].to_s.strip if permitted.key?(:name)
    permitted[:time_zone] = permitted[:time_zone].to_s.strip.presence if permitted.key?(:time_zone)
    permitted
  end
end
