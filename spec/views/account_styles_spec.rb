require "rails_helper"

RSpec.describe "Account views' own styles" do
  def foreign_classes(source)
    markup = ViewStyles.outside_style_blocks(source)
    selected = ViewStyles.rules(source).flat_map(&:selectors).flat_map { |selector| selector.scan(/\.([a-z][\w-]*)/) }.flatten.uniq
    selected.reject { |name| markup.match?(/(?<![\w-])#{Regexp.escape(name)}(?![\w-])/) }
  end

  it "sees a class selected inside an at-rule" do
    source = %(<style>.own { color: red; } @media (max-width: 600px) { .foreign { color: blue; } }</style><p class="own"></p>)

    expect(foreign_classes(source)).to eq([ "foreign" ])
  end

  Dir[Rails.root.join("app/views/accounts/*.erb")].sort.each do |path|
    view = Pathname(path).relative_path_from(Rails.root).to_s

    it "keeps #{view}'s style to classes its own markup carries" do
      foreign = foreign_classes(File.read(path))

      expect(foreign).to be_empty, "#{view} styles #{foreign.join(', ')}, which its markup never uses. Move each rule to the view that renders that class."
    end
  end
end
