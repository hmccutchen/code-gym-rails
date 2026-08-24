class ProfileController < ApplicationController
  # Name editing needs a logged-in user but not an API key, so this endpoint
  # stays a clean JSON surface regardless of key state.
  skip_before_action :require_api_key

  # PATCH /profile — inline name autosave (JSON)
  def update
    return render_invalid_boolean if invalid_adaptive_set_size?

    if current_user.update(profile_params)
      render json: { name: current_user.name, time_zone: current_user.time_zone,
                     adaptive_set_size: current_user.adaptive_set_size }
    else
      render json: { errors: current_user.errors.full_messages },
             status: :unprocessable_content
    end
  end

  private

  # adaptive_set_size backs a `null: false` column, and Active Record's cast is
  # too forgiving for a request boundary: "" and null become nil (a 500 from
  # the database), and any other string — "banana" included — becomes true,
  # silently flipping the preference a malformed request got wrong. Only these
  # literal values are accepted.
  BOOLEAN_VALUES = [ true, false, "true", "false", "1", "0", 1, 0 ].freeze

  def invalid_adaptive_set_size?
    user_params = params.require(:user)

    user_params.key?(:adaptive_set_size) &&
      BOOLEAN_VALUES.exclude?(user_params[:adaptive_set_size])
  end

  def render_invalid_boolean
    render json: { errors: [ "Adaptive set size must be true or false" ] },
           status: :unprocessable_content
  end

  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :adaptive_set_size)
    permitted[:name] = permitted[:name].to_s.strip if permitted.key?(:name)
    permitted[:time_zone] = permitted[:time_zone].to_s.strip.presence if permitted.key?(:time_zone)
    permitted
  end
end
