# The layout mounts the mermaid controller on every page; it imports Mermaid only when this selector finds a diagram.
module MermaidHelpers
  def diagrams_awaiting_mermaid(html)
    selector = Rails.root.join("app/javascript/controllers/mermaid_controller.js").read[/querySelectorAll\("([^"]+)"\)/, 1]
    raise "mermaid_controller.js no longer names its diagram selector in one querySelectorAll call" if selector.nil?

    Nokogiri::HTML(html).css(selector)
  end
end

RSpec.configure do |config|
  config.include MermaidHelpers, type: :request
end
