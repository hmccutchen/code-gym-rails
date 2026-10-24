require "rails_helper"

RSpec.describe "Styles on the Account page" do
  def style_block = %r{<style>(.*?)</style>}m

  def selected_classes(source)
    source.scan(style_block).flatten.flat_map { |css| css.gsub(/\{[^}]*\}/, "").scan(/\.([a-z][\w-]*)/) }.flatten.uniq
  end

  def markup(source) = source.gsub(style_block, "")

  Dir[Rails.root.join("app/views/accounts/*.erb")].sort.each do |path|
    view = Pathname(path).relative_path_from(Rails.root).to_s

    it "keeps #{view}'s style to classes its own markup carries" do
      source = File.read(path)
      foreign = selected_classes(source).reject { |name| markup(source).match?(/(?<![\w-])#{Regexp.escape(name)}(?![\w-])/) }

      expect(foreign).to be_empty, "#{view} styles #{foreign.join(', ')}, which its markup never uses. Move each rule to the view that renders that class."
    end
  end
end
