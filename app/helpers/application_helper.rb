module ApplicationHelper
  def practice_display_status
    @practice_display_status ||= current_user.present? ? PracticePolicyMode.display_status(current_user) : :inactive
  end

  def practice_copy(key, **values)
    return t("protected_practice.unavailable") if practice_display_status == :unavailable

    t(practice_display_status == :active ? "protected_practice.#{key}" : key, **values)
  end

  def practice_notes(exercise)
    return [ t("protected_practice.unavailable") ] if practice_display_status == :unavailable

    note = exercise.practice_schedule
    replacement = (note.fetch("selected_kinds", []) - note.fetch("regular_kinds", [])) & exercise.active_section_keys
    lines = []
    if note["omitted_kind"] && replacement.any?
      lines << t("protected_practice.dashboard.variety", kind: t("sections.#{replacement.first}.name"))
    end
    if exercise.active_section_keys.any? { |key| exercise.problem_set.dig(key, "practice_adjustment") == "simplified" }
      lines << t("protected_practice.dashboard.adjusted")
    end
    lines
  rescue ArgumentError => error
    Rails.logger.warn("[practice_display] user_id=#{exercise.user_id} exercise_id=#{exercise.id} error=#{error.class.name}")
    [ t("protected_practice.unavailable") ]
  end

  def page_title(title)
    content_for(:title, title)
  end

  # The title is what a screen reader announces on arrival and what the iOS app switcher shows.
  def document_title
    content_for?(:title) ? safe_join([ content_for(:title), t("app_name") ], " – ") : t("app_name")
  end

  def wide_page
    content_for(:container_width, "wide", flush: true)
  end

  def page_stylesheet(name)
    content_for(:page_stylesheet, name, flush: true)
  end

  def component_stylesheet(name)
    component_stylesheets << name unless component_stylesheets.include?(name)
  end

  # Components first, so the page's own rules win their ties with a shared component's.
  def linked_stylesheets
    page = content_for?(:page_stylesheet) ? [ "pages/#{content_for(:page_stylesheet)}" ] : []
    component_stylesheets.map { |name| "components/#{name}" } + page
  end

  def container_class
    content_for(:container_width) == "wide" ? "container container-wide" : "container"
  end

  private

  def component_stylesheets = (@component_stylesheets ||= [])
end
