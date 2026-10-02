module DisplayPreferencesHelper
  def display_preferences
    @display_preferences ||= logged_in? ? DisplayPreferences.for(current_user) : DisplayPreferences.signed_out
  end

  # Setup always links the optional stylesheets so a choice applies before
  # it is saved. The default-on pattern's base styles live in the layout.
  def display_stylesheets?
    display_preferences.any? || content_for?(:display_controls)
  end

  def html_display_attributes
    attributes = display_preferences.html_attributes
    attributes.any? ? " #{tag.attributes(attributes)}".html_safe : ""
  end

  # The outlined logo was drawn for dark backgrounds. The plain one takes over
  # wherever the light palette applies, through the same media value as the
  # palette's own <link>, so the two can never disagree.
  def brand_mark
    outlined = image_tag("logo-outlined.png", alt: t("app_name"), class: "brand-mark", width: 930, height: 654)
    return outlined unless display_stylesheets?

    tag.picture do
      tag.source(srcset: image_path("logo.png"), media: display_preferences.light_palette_media,
                 data: { light_palette_media: true }) + outlined
    end
  end
end
