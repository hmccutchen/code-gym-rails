require "rails_helper"

RSpec.describe "Conventions held over app/views" do
  def view_files = Dir[Rails.root.join("app/views/**/*.erb")].sort

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def inline_handler
    event = "on(?!(?:ly|ce|e|line|boarding)\\b)[a-z]+"
    /(?<![\w-])#{event}["']?\s*(?:=|:(?!:))|["'=]\s*javascript:/i
  end

  def offending_lines(pattern)
    view_files.flat_map do |path|
      File.readlines(path).filter_map.with_index(1) do |line, number|
        "#{relative(path)}:#{number}" if line.match?(pattern)
      end
    end
  end

  def inline_script = /<script\b|\bjavascript_tag\b|\btag\.script\b|\b(?:content_)?tag[ (]\s*[:"']script\b/i

  it "keeps every page script in a Stimulus controller rather than an inline tag" do
    offenders = offending_lines(inline_script)

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
    expect(%(button_tag "Go", onclick: handler)).to match(inline_handler)
    expect(%(<button onclick=go()>)).to match(inline_handler)
    expect(%(<a href=javascript:void(0)>)).to match(inline_handler)
    expect(%(button_tag "Go", "onclick" => "go()")).to match(inline_handler)
    expect(%(tag.div "onwheel" => handler)).to match(inline_handler)
    expect(%(render "x", only: "y")).not_to match(inline_handler)
    expect(%(link_to "x", path, once: "y")).not_to match(inline_handler)
    expect(%(<div data-action="click->x#go">)).not_to match(inline_handler)
    expect(%(Online::Thing)).not_to match(inline_handler)
  end

  it "recognises the script tags Rails helpers write" do
    expect(%(<script type="module">)).to match(inline_script)
    expect(%(<%= javascript_tag "go()" %>)).to match(inline_script)
    expect(%(<%= tag.script "go()" %>)).to match(inline_script)
    expect(%(<%= content_tag :script, "go()" %>)).to match(inline_script)
    expect(%(<%= content_tag "script", "go()" %>)).to match(inline_script)
    expect(%(<%= tag("script", nil, true) %>)).to match(inline_script)
    expect(%(<%= javascript_include_tag "app" %>)).not_to match(inline_script)
    expect(%(<%= javascript_importmap_tags %>)).not_to match(inline_script)
  end

  it "keeps a page's styles in its own stylesheet, never a <style> block in its views" do
    paged = Dir[Rails.root.join("app/views/{history,progress,accounts,api_keys,dashboard}/*.erb")] +
            %w[index.html.erb _recognition_guide.html.erb].map { |name| Rails.root.join("app/views/learn", name).to_s }
    offenders = paged.select { |path| File.read(path).match?(/<style\b/) }.map { |path| relative(path) }

    expect(offenders).to be_empty, "#{offenders.join(', ')} carry a <style> block; move it to app/assets/stylesheets/pages (docs/decisions/page-stylesheets.md)"
  end

  it "keeps Today's styles out of style attributes in its views" do
    today = Dir[Rails.root.join("app/views/{dashboard,responses}/**/*.erb")]
    offenders = today.select { |path| File.read(path).match?(/\bstyle\s*[=:]/) }.map { |path| relative(path) }

    expect(offenders).to be_empty, "#{offenders.join(', ')} carry a style attribute; give the element a class, styled in pages/today.css or, for a partial History also renders, the layout"
  end

  PAGE_SHEET_PARTIALS = { %r{\Aaccounts/} => "app/views/accounts/show.html.erb",
                          %r{\Adashboard/(?!teaching_hint\z)} => "app/views/dashboard/show.html.erb",
                          %r{\Aresponses/submission\z} => "app/views/dashboard/show.html.erb",
                          %r{\Aapi_keys/} => "app/views/api_keys/edit.html.erb",
                          %r{\Alearn/recognition_guide\z} => "app/views/learn/index.html.erb" }.freeze

  def rendered_partials(source) = source.scan(/\brender[ (]+(?:partial:\s*)?["']([\w\/]+)["']/).flatten

  def page_for(partial) = PAGE_SHEET_PARTIALS.find { |pattern, _| partial.match?(pattern) }&.last

  it "renders a partial styled by a page sheet only on the page that links that sheet" do
    offenders = Dir[Rails.root.join("app/{views,controllers,helpers}/**/*.{erb,rb}")].flat_map do |path|
      rendered_partials(File.read(path)).filter_map do |partial|
        page = page_for(partial)
        "#{relative(path)} renders #{partial}" if page && relative(path) != page && !relative(path).start_with?(File.dirname(page) + "/_")
      end
    end

    expect(offenders).to be_empty, "#{offenders.join(', ')}; its styles live in that page's sheet, so give it a shared sheet named for the component (docs/decisions/page-stylesheets.md)"
  end

  it "recognises the partial a render names" do
    expect(rendered_partials(%(<%= render "accounts/api_usage", usage: u %>))).to eq([ "accounts/api_usage" ])
    expect(rendered_partials(%(<%= render(partial: "api_keys/key_guide") %>))).to eq([ "api_keys/key_guide" ])
    expect(page_for("learn/recognition_guide")).to eq("app/views/learn/index.html.erb")
    expect(page_for("learn/concept")).to be_nil
    expect(page_for("dashboard/teaching_hint")).to be_nil
  end
end
