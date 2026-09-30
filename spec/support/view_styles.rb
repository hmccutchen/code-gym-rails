# Reads the CSS in a view's <style> blocks as flat rules, for specs that check
# what the stylesheet says rather than what a browser renders. Enough CSS for
# this app's hand-written styles: comments, nested @media and @keyframes
# blocks, and selector lists. Not a general CSS parser.
module ViewStyles
  Rule = Struct.new(:selectors, :declarations, :media, keyword_init: true) do
    def declaration(property)
      declarations[/(?:\A|;)\s*#{Regexp.escape(property)}\s*:\s*([^;]+)/, 1]&.strip
    end
  end

  module_function

  def style_blocks(source)
    source.scan(%r{<style>(.*?)</style>}m).flatten
  end

  def outside_style_blocks(source)
    source.gsub(%r{<style>.*?</style>}m, "")
  end

  def rules(source)
    style_blocks(source).flat_map { |css| rules_in(css.gsub(%r{/\*.*?\*/}m, "")) }
  end

  # The same, for a plain .css file rather than a view's <style> blocks.
  def stylesheet_rules(path)
    rules_in(File.read(path).gsub(%r{/\*.*?\*/}m, ""))
  end

  # Walks the braces, keeping the enclosing at-rule preludes so a rule inside
  # `@media (prefers-reduced-motion: reduce)` knows it is there.
  def rules_in(css)
    rules = []
    preludes = []
    buffer = +""
    css.each_char do |char|
      case char
      when "{"
        preludes << buffer.strip
        buffer = +""
      when "}"
        prelude = preludes.pop
        if buffer.strip.present? && !prelude.start_with?("@")
          rules << Rule.new(selectors: prelude.split(",").map(&:squish),
                            declarations: buffer.strip, media: preludes.select { |p| p.start_with?("@") })
        end
        buffer = +""
      else
        buffer << char
      end
    end
    rules
  end

  # The custom properties a :root block declares, as name => value. Takes a
  # view's source, or rules already read from a stylesheet.
  def root_variables(source_or_rules)
    all = source_or_rules.is_a?(String) ? rules(source_or_rules) : source_or_rules
    root = all.find { |rule| rule.selectors == [ ":root" ] && rule.media.empty? }
    root.declarations.scan(/--([\w-]+)\s*:\s*([^;]+)/).to_h { |name, value| [ name, value.strip ] }
  end
end
