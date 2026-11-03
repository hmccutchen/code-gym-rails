module ApplicationHelper
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
