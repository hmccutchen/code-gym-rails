module ApplicationHelper
  def page_title(title)
    content_for(:title, title)
  end

  # The title is what a screen reader announces on arrival and what the iOS app switcher shows.
  def document_title
    content_for?(:title) ? safe_join([ content_for(:title), t("app_name") ], " – ") : t("app_name")
  end
end
