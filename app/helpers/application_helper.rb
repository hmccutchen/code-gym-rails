module ApplicationHelper
  def page_title(title)
    content_for(:title, title)
  end

  # Every page has to name itself: the app name alone is what a screen reader
  # announces on arrival and what an iOS app switcher shows for each page.
  def document_title
    content_for?(:title) ? safe_join([ content_for(:title), t("app_name") ], " – ") : t("app_name")
  end
end
