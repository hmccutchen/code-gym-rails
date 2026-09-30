# A user's display choices as plain values, and what the layout renders for
# them. Each setting lists its default first. A default is never stored, so a
# user who has changed nothing stores {} and the layout renders nothing new.
#
# Total by construction: a stored value outside OPTIONS reads as the default,
# so bad data can never reach an attribute on <html>.
class DisplayPreferences
  OPTIONS = {
    "theme"        => %w[dark light device],
    "text_size"    => %w[100 112 125 140],
    "line_spacing" => %w[default relaxed loose],
    "font"         => %w[default atkinson]
  }.freeze

  # The iOS home-screen app reads these when it launches. "black" is a solid
  # bar with white text above the page, readable under either theme, so only
  # an explicit light choice asks for the white bar.
  STATUS_BAR_STYLES = { "light" => "default" }.freeze
  THEME_COLORS      = { "light" => "#ffffff" }.freeze

  # Where the light palette applies, as the media attribute of its <link>.
  LIGHT_PALETTE_MEDIA = { "light" => "all", "device" => "(prefers-color-scheme: light)" }.freeze
  LIGHT_PALETTE_OFF   = "not all"

  def self.for(user)
    new(user.display_preferences)
  end

  # A signed-out page has nothing stored, so it follows the device.
  def self.signed_out
    new("theme" => "device")
  end

  # Drops keys set to their default. Unknown keys and values stay, so the
  # validation that runs after this still sees and refuses them.
  def self.sparse(values)
    return values unless values.is_a?(Hash)

    values.reject { |key, value| OPTIONS[key]&.first == value }
  end

  def self.problems_with(values)
    return [ "must be an object" ] unless values.is_a?(Hash)

    values.filter_map do |key, value|
      if OPTIONS.exclude?(key) then "names an unknown setting: #{key}"
      elsif OPTIONS[key].exclude?(value) then "has an unsupported #{key.humanize(capitalize: false)}: #{value}"
      end
    end
  end

  def initialize(values)
    @values = values.is_a?(Hash) ? values : {}
  end

  def [](key)
    value = @values[key]
    OPTIONS.fetch(key).include?(value) ? value : OPTIONS[key].first
  end

  def chosen
    OPTIONS.keys.reject { |key| self[key] == OPTIONS[key].first }.index_with { |key| self[key] }
  end

  def any?
    chosen.any?
  end

  def html_attributes
    chosen.transform_keys { |key| "data-#{key.dasherize}" }
  end

  def light_palette_media
    LIGHT_PALETTE_MEDIA.fetch(self["theme"], LIGHT_PALETTE_OFF)
  end

  def status_bar_style
    STATUS_BAR_STYLES.fetch(self["theme"], "black")
  end

  def theme_color
    THEME_COLORS.fetch(self["theme"], "#1a1a2e")
  end
end
