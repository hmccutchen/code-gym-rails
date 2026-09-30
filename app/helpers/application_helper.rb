module ApplicationHelper
  APP_NAME = "Code Gym".freeze

  def page_title(title)
    content_for(:title, title)
  end

  # Every page has to name itself: the app name alone is what a screen reader
  # announces on arrival and what an iOS app switcher shows for each page.
  def document_title
    content_for?(:title) ? safe_join([ content_for(:title), APP_NAME ], " – ") : APP_NAME
  end
end
