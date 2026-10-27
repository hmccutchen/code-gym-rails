require "rails_helper"

RSpec.describe "page stylesheets" do
  DESKTOP_QUERY = "@media (min-width: 900px)".freeze
  ALLOWED_QUERIES = {
    "history" => [ DESKTOP_QUERY ],
    "progress" => [ DESKTOP_QUERY, "@media (min-width: 600px)" ],
    "learn" => [ DESKTOP_QUERY ],
    "account" => [ DESKTOP_QUERY ],
    "settings" => [ DESKTOP_QUERY, "@media (forced-colors: active)" ],
    "today" => [ "@media (prefers-reduced-motion: reduce)", "@media (max-width: 599.98px)" ]
  }.freeze

  def path_for(page) = Rails.root.join("app/assets/stylesheets/pages/#{page}.css")

  def rules_for(page) = ViewStyles.stylesheet_rules(path_for(page))

  # Whatever follows the closing brace of the one 900px block, ignoring comments and whitespace.
  def after_desktop_block(css)
    source = css.gsub(%r{/\*.*?\*/}m, "")
    start = source.index(DESKTOP_QUERY)
    return nil if start.nil? || source.index(DESKTOP_QUERY, start + 1)

    depth = 0
    close_brace = (source.index("{", start)...source.length).find do |i|
      depth += 1 if source[i] == "{"
      depth -= 1 if source[i] == "}"
      depth.zero?
    end
    source[(close_brace + 1)..].strip
  end

  # The Learn filter sets [hidden] on its buckets, group blocks and entries; the last compound is the styled element.
  def hidden_by_filter?(selector)
    selector.split(/\s*[ >+~]\s*/).last.match?(/\.learn-(bucket|group-block|entry)\b/)
  end

  it "has a sheet for each page, and no other" do
    sheets = Rails.root.glob("app/assets/stylesheets/pages/*.css").map { |path| path.basename(".css").to_s }

    expect(sheets).to match_array(ALLOWED_QUERIES.keys)
  end

  ALLOWED_QUERIES.each do |page, queries|
    it "keeps #{page}.css to its own media queries" do
      used = rules_for(page).flat_map(&:media).uniq

      expect(used - queries).to be_empty, "#{page}.css adds #{(used - queries).join(', ')}; a new query is a decision"
    end

    next unless queries.include?(DESKTOP_QUERY)

    it "ends #{page}.css with its one 900px block, so a desktop rule wins every tie with the page's phone rules" do
      expect(after_desktop_block(path_for(page).read)).to eq("")
    end
  end

  it "notices a rule left after the 900px block, and a sheet with no 900px block" do
    css = "#{DESKTOP_QUERY} { .a { color: red; } }\n.b { color: blue; }"

    expect(after_desktop_block(css)).to eq(".b { color: blue; }")
    expect(after_desktop_block(".b { color: blue; }")).to be_nil
  end

  it "never outweighs the card page's [hidden] rule on an element the Learn filter hides, at any width" do
    weighty = rules_for("learn").select { |rule| rule.declaration("display") }.flat_map(&:selectors)
                                .reject { |selector| selector.match?(/\A\.[a-z-]+\z/) || selector.end_with?("[hidden]") }

    weighty.each do |selector|
      expect(hidden_by_filter?(selector)).to be(false), "#{selector} sets display at the weight of :is(.phone-page, .card-page) [hidden] or more"
    end
  end

  it "recognizes a hidden element in any form of the selector's last part" do
    hidden = [ ".learn-page .learn-bucket", ".learn-page .learn-bucket-grouped", ".learn-page section.learn-bucket.learn-bucket-grouped",
               ".learn-page .learn-bucket:not(.x)", ".learn-page .learn-group-block.card", ".learn-groups > .learn-entry" ]
    shown = [ ".learn-page .learn-buckets", ".learn-page .learn-bucket-grouped .learn-groups", ".learn-page .learn-entry a" ]

    expect(hidden.map { |selector| hidden_by_filter?(selector) }).to all(be(true))
    expect(shown.map { |selector| hidden_by_filter?(selector) }).to all(be(false))
  end
end
