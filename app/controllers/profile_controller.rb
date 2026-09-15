class ProfileController < ApplicationController
  # Name editing needs a logged-in user but not an API key, so this endpoint
  # stays a clean JSON surface regardless of key state.
  skip_before_action :require_api_key

  # PATCH /profile — inline name autosave (JSON)
  def update
    return render_invalid_boolean if invalid_adaptive_set_size?
    return render_invalid_weight  if invalid_section_kind_weights?

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

  # A weight arrives from a range input indexing a server-rendered list, so a
  # non-numeric or off-stop value means a malformed request rather than a user
  # action. Rejected here for the same reason as BOOLEAN_VALUES above: the
  # column's cast would quietly turn "0.25" into 0.0.
  def invalid_section_kind_weights?
    weights = params.require(:user)[:section_kind_weights]
    return false if weights.blank?
    return true  unless weights.respond_to?(:to_unsafe_h)

    weights.to_unsafe_h.values.any? { |value| !value.is_a?(Numeric) || KindPreferences::MULTIPLIERS.exclude?(value.to_f) }
  end

  def render_invalid_weight
    render json: { errors: [ "Section weight must be one of #{KindPreferences::MULTIPLIERS.join(', ')}" ] },
           status: :unprocessable_content
  end

  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :adaptive_set_size,
                                             section_kind_weights: {}, excluded_section_kinds: [])
    permitted[:name] = permitted[:name].to_s.strip if permitted.key?(:name)
    permitted[:time_zone] = permitted[:time_zone].to_s.strip.presence if permitted.key?(:time_zone)
    # permit(x: {}) yields Parameters, which a jsonb column cannot serialize.
    permitted[:section_kind_weights] = permitted[:section_kind_weights].to_h if permitted.key?(:section_kind_weights)
    permitted
  end
end
