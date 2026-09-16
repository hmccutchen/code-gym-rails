class ProfileController < ApplicationController
  include ExerciseMixLadders

  # Name editing needs a logged-in user but not an API key, so this endpoint
  # stays a clean JSON surface regardless of key state.
  skip_before_action :require_api_key

  # PATCH /profile — inline profile autosave (JSON)
  def update
    return render_invalid_boolean   if invalid_adaptive_set_size?
    return render_invalid_weight    if invalid_section_kind_weights?
    return render_invalid_exclusion if invalid_excluded_section_kinds?
    return render_invalid_level     if invalid_section_kind_levels?
    return render_invalid_lock      if invalid_locked_section_kinds?

    saved = save_with_preference_precondition

    return render_stale_preferences if saved == :stale

    if saved
      render json: saved_body
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
  PREFERENCE_KEYS = %i[section_kind_weights excluded_section_kinds section_kind_levels locked_section_kinds].freeze

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
  # action. jsonb stores whatever it is handed, so a stray string would persist
  # as a string rather than being coerced — the model validation would also
  # catch it, but this boundary guard is deliberate defence-in-depth, and it
  # fails with a message naming the allowed stops rather than a generic
  # object-shape error.
  # Only an ABSENT key skips the check. A present-but-wrong-shaped value (an
  # array, a bare null) would otherwise pass as blank, be dropped by
  # strong parameters, and return 200 having applied nothing the request asked
  # for — a success status for a write that did not happen. An empty object is
  # a real instruction (clear every weight) and still passes.
  def invalid_section_kind_weights?
    user_params = params.require(:user)
    return false unless user_params.key?(:section_kind_weights)

    weights = user_params[:section_kind_weights]
    return true unless weights.respond_to?(:to_unsafe_h)

    weights.to_unsafe_h.values.any? { |value| !value.is_a?(Numeric) || KindPreferences::MULTIPLIERS.exclude?(value.to_f) }
  end

  def render_invalid_weight
    render json: { errors: [ "Section weight must be one of #{KindPreferences::MULTIPLIERS.join(', ')}" ] },
           status: :unprocessable_content
  end

  def invalid_excluded_section_kinds?
    invalid_string_list?(:excluded_section_kinds)
  end

  def invalid_locked_section_kinds?
    invalid_string_list?(:locked_section_kinds)
  end

  # permit(key: []) silently drops any non-scalar entry rather than rejecting the
  # request, so a malformed payload like [{"a":1}] would otherwise arrive as []
  # and clear the stored list with a 200. Checked against the raw param, before
  # permit has thrown the bad entries away. Absent skips; an empty array is a
  # real instruction to clear.
  def invalid_string_list?(key)
    user_params = params.require(:user)
    return false unless user_params.key?(key)

    list = user_params[key]
    return true unless list.is_a?(Array)

    list.any? { |entry| !entry.is_a?(String) }
  end

  def render_invalid_exclusion
    render json: { errors: [ "Excluded section kinds must be a list of strings" ] },
           status: :unprocessable_content
  end

  # Same reasoning as the weights guard: a present-but-wrong-shaped value must
  # fail rather than be dropped by strong parameters and reported as a success.
  def invalid_section_kind_levels?
    user_params = params.require(:user)
    return false unless user_params.key?(:section_kind_levels)

    levels = user_params[:section_kind_levels]
    return true unless levels.respond_to?(:to_unsafe_h)

    levels.to_unsafe_h.values.any? { |value| !value.is_a?(String) || KindDifficulty::LEVELS.exclude?(value) }
  end

  def render_invalid_level
    render json: { errors: [ "Section difficulty must be one of #{KindDifficulty::LEVELS.join(', ')}" ] },
           status: :unprocessable_content
  end

  def render_invalid_lock
    render json: { errors: [ "Locked section kinds must be a list of strings" ] },
           status: :unprocessable_content
  end

  # The mix controls post the version they last saw, so a tab whose DOM predates
  # another tab's save is refused instead of overwriting it. Absent version
  # means no precondition, the way an absent If-Match does — the other autosaves
  # on this page send none and are unaffected.
  #
  # Read and write sit inside one row lock, the same shape User#anonymize! uses:
  # unlocked they are two statements a second request can interleave with, and
  # both requests would pass a check against the version neither had bumped yet.
  def save_with_preference_precondition
    posted = params.require(:user)[:section_kind_preferences_version]
    return current_user.update(profile_params) if posted.nil?

    outcome = nil
    current_user.with_lock do
      outcome = if posted.to_s == current_user.section_kind_preferences_version.to_s
        current_user.update(profile_params)
      else
        :stale
      end
    end
    outcome
  end

  # Carries the state the refused tab does not have, so it can show what is
  # actually stored rather than retrying against a version that will never
  # match again.
  def render_stale_preferences
    render json: {
      errors: [ t("exercise_mix.conflict") ],
      current: {
        section_kind_weights:             current_user.section_kind_weights,
        excluded_section_kinds:           current_user.excluded_section_kinds,
        section_kind_levels:              current_user.section_kind_levels,
        locked_section_kinds:             current_user.locked_section_kinds,
        section_kind_preferences_version: current_user.section_kind_preferences_version,
        ladder_preparation:               ladder_preparation
      }
    }, status: :conflict
  end

  # The version rides along only when the request touched the preferences, so
  # the body every other caller sees is byte-identical to before.
  def saved_body
    body = { name: current_user.name, time_zone: current_user.time_zone,
             adaptive_set_size: current_user.adaptive_set_size }
    return body unless preference_update?

    body.merge(section_kind_preferences_version: current_user.section_kind_preferences_version,
               ladder_preparation: ladder_preparation)
  end

  def preference_update?
    user_params = params.require(:user)
    PREFERENCE_KEYS.any? { |key| user_params.key?(key) }
  end

  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :adaptive_set_size,
                                             section_kind_weights: {}, excluded_section_kinds: [],
                                             section_kind_levels: {}, locked_section_kinds: [])
    permitted[:name] = permitted[:name].to_s.strip if permitted.key?(:name)
    permitted[:time_zone] = permitted[:time_zone].to_s.strip.presence if permitted.key?(:time_zone)
    # permit(x: {}) yields Parameters, which a jsonb column cannot serialize.
    %i[section_kind_weights section_kind_levels].each do |key|
      permitted[key] = permitted[key].to_h if permitted.key?(key)
    end
    permitted
  end
end
