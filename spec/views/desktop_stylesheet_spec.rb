require "rails_helper"

RSpec.describe "desktop stylesheet" do
  let(:path) { Rails.root.join("app/assets/stylesheets/desktop.css") }
  let(:rules) { ViewStyles.stylesheet_rules(path) }

  def desktop_query = "@media (min-width: 900px)"

  # Whatever text sits outside the one 900px block, ignoring comments and whitespace.
  def outside_the_block(css)
    source = css.gsub(%r{/\*.*?\*/}m, "")
    start = source.index(desktop_query)
    return source.strip if start.nil?

    open_brace = source.index("{", start)
    depth = 0
    close_brace = (open_brace...source.length).find do |i|
      depth += 1 if source[i] == "{"
      depth -= 1 if source[i] == "}"
      depth.zero?
    end
    (source[0...start] + source[(close_brace + 1)..]).strip
  end

  it "holds only rules that apply at 900px and wider, so no phone width ever reads it" do
    expect(rules).not_to be_empty
    rules.each do |rule|
      expect(rule.media).to eq([ desktop_query ]), "#{rule.selectors.join(', ')} sits under #{rule.media.inspect}"
    end
  end

  it "has nothing outside its one 900px block, at-rules like @font-face included" do
    expect(outside_the_block(File.read(path))).to eq("")
  end

  it "scopes every rule to a page class, the wide container or the nav" do
    scoped = /\A(\.[a-z-]+-page\b|\.container\.container-wide\z|nav\b)/
    rules.flat_map(&:selectors).each do |selector|
      expect(selector).to match(scoped), "#{selector} isn't scoped to a page"
    end
  end

  it "notices an at-rule left outside the block" do
    css = "#{desktop_query} { .a { color: red; } }\n@font-face { font-family: X; src: url(x.woff2); }"

    expect(outside_the_block(css)).to start_with("@font-face")
  end

  it "loads after the phone card styles, so a desktop rule wins a tie with the phone rule it replaces" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    phone = layout.index('stylesheet_link_tag "phone_cards"')
    desktop = layout.index('stylesheet_link_tag "desktop"')

    expect(phone).to be_present
    expect(desktop).to be_present
    expect(desktop).to be > phone
  end

  it "loads after the layout's own styles, so its nav cap wins the tie with the layout's same-specificity rule" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read

    expect(layout.scan("</style>").size).to eq(1)
    expect(layout.index('stylesheet_link_tag "desktop"')).to be > layout.index("</style>")
  end
end
