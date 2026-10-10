# A stored value outside OPTIONS reads as the default, so bad data never reaches <html>.
class DisplayPreferences
  OPTIONS = {
    "theme"        => %w[dark light device],
    "text_size"    => %w[100 112 125 140],
    "line_spacing" => %w[default relaxed loose],
    "font"         => %w[default atkinson],
    "background_pattern" => %w[on off]
  }.freeze

  # "black" reads under either theme, so only an explicit light choice asks for the white bar.
  STATUS_BAR_STYLES = { "light" => "default" }.freeze

  # The dark color is always rendered as the fallback; the light one carries the light palette's media.
  DARK_THEME_COLOR  = "#1a1a2e"
  LIGHT_THEME_COLOR = "#ffffff"

  LIGHT_PALETTE_MEDIA = { "light" => "all", "device" => "(prefers-color-scheme: light)" }.freeze
  LIGHT_PALETTE_OFF   = "not all"

  def self.for(user)
    new(user.display_preferences)
  end

  # A signed-out page has nothing stored, so it follows the device.
  def self.signed_out
    new("theme" => "device")
  end

  # Unknown keys and values stay, so the validation that runs after this still refuses them.
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
end
