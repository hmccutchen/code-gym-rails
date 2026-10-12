module DisplayPreferencesHelper
  def display_preferences
    @display_preferences ||= logged_in? ? DisplayPreferences.for(current_user) : DisplayPreferences.signed_out
  end

  # Setup always links the optional stylesheets so a choice applies before it is saved.
  def display_stylesheets?
    display_preferences.any? || content_for?(:display_controls)
  end

  def html_display_attributes
    attributes = display_preferences.html_attributes
    attributes.any? ? " #{tag.attributes(attributes)}".html_safe : ""
  end

  # Uses the light palette's own media value, so the logo and palette can never disagree.
  def brand_mark
    mark = image_tag("brand-mark.png", alt: t("app_name"), class: "brand-mark", width: 723, height: 492)
    return mark unless display_stylesheets?

    tag.picture do
      tag.source(srcset: image_path("brand-mark-light.png"), media: display_preferences.light_palette_media,
                 width: 512, height: 512, data: { light_palette_media: true }) + mark
    end
  end
end
