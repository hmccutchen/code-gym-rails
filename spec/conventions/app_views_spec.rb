require "rails_helper"

RSpec.describe "Conventions held over app/views" do
  def view_files = Dir[Rails.root.join("app/views/**/*.erb")].sort

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def inline_handler
    event = "on(?!(?:ly|ce|e|line|boarding)\\b)[a-z]+"
    /(?<![\w-])#{event}(?:\s*=|"?:)\s*["']|["']\s*javascript:/i
  end

  def offending_lines(pattern)
    view_files.flat_map do |path|
      File.readlines(path).filter_map.with_index(1) do |line, number|
        "#{relative(path)}:#{number}" if line.match?(pattern)
      end
    end
  end

  it "keeps every page script in a Stimulus controller rather than an inline tag" do
    offenders = offending_lines(/<script\b/i)

    expect(offenders).to be_empty, <<~MESSAGE
      Inline <script> in a view: #{offenders.join(', ')}.
      The content security policy allows a script only from this origin or a
      nonce the importmap tags carry, so an inline tag never runs. Put the
      behaviour in app/javascript/controllers and bind it with data-action.
    MESSAGE
  end

  it "binds behaviour with data-action rather than an inline event handler or javascript: URL" do
    offenders = offending_lines(inline_handler)

    expect(offenders).to be_empty, <<~MESSAGE
      Inline handler in a view: #{offenders.join(', ')}.
      The content security policy refuses an on* attribute and a javascript:
      URL the same way it refuses an inline <script>. Bind the behaviour with
      data-action to a Stimulus controller.
    MESSAGE
  end

  it "recognises the handler shapes it guards against" do
    expect(%(<button onclick="go()">)).to match(inline_handler)
    expect(%(button_tag "Go", onclick: "go()")).to match(inline_handler)
    expect(%(tag.div "data-x": 1, "onchange": "go()")).to match(inline_handler)
    expect(%(<a href="javascript:void(0)">)).to match(inline_handler)
    expect(%(<div onanimationend="go()">)).to match(inline_handler)
    expect(%(tag.div onwheel: "go()")).to match(inline_handler)
    expect(%(render "x", only: "y")).not_to match(inline_handler)
    expect(%(link_to "x", path, once: "y")).not_to match(inline_handler)
    expect(%(<div data-action="click->x#go">)).not_to match(inline_handler)
  end
end
