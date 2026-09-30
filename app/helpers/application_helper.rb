module ApplicationHelper
  def page_title
    [ content_for(:title).presence, "Code Gym" ].compact.join(" — ")
  end
end
