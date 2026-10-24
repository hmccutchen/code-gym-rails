# Enough CSS for this app's hand-written styles; not a general CSS parser.
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

  ERB_TAG = /<%.*?%>/m
  STRING_LITERAL = /"([^"]*)"|'([^']*)'/
  CLASS_ATTRIBUTE = /(?<![\w-])class=(?:"((?:<%.*?%>|[^"])*?)"|'((?:<%.*?%>|[^'])*?)')/m
  HELPER_CLASS = /(?<![\w])class:\s*(?:"([^"]*)"|'([^']*)')/

  # A name joined to Ruby, like slot-<%= n %>, yields only its static pieces, so a rule on the joined name fails.
  def markup_classes(source)
    markup = outside_style_blocks(source)
    attribute_values = markup.scan(CLASS_ATTRIBUTE).map(&:compact).flatten.map do |value|
      value.gsub(ERB_TAG) { |tag| " #{tag.scan(STRING_LITERAL).flatten.compact.join(' ')} " }
    end
    helper_values = markup.scan(ERB_TAG).flat_map { |tag| tag.scan(HELPER_CLASS).flatten.compact }
    (attribute_values + helper_values).flat_map { |value| value.gsub(/#\{[^}]*\}/, " ").split }.uniq
  end

  def selected_classes(rules)
    rules.flat_map(&:selectors).flat_map { |selector| without_negations(selector).scan(/\.([a-z][\w-]*)/) }.flatten.uniq
  end

  def without_negations(selector)
    selector.gsub(/:not(\((?:[^()]|\g<1>)*\))/, "")
  end

  def rules(source)
    style_blocks(source).flat_map { |css| rules_in(css.gsub(%r{/\*.*?\*/}m, "")) }
  end

  # The same, for a plain .css file rather than a view's <style> blocks.
  def stylesheet_rules(path)
    rules_in(File.read(path).gsub(%r{/\*.*?\*/}m, ""))
  end

  # Keeps enclosing at-rule preludes so a rule inside a prefers-reduced-motion block knows it is there.
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

  def root_variables(source_or_rules)
    all = source_or_rules.is_a?(String) ? rules(source_or_rules) : source_or_rules
    root = all.find { |rule| rule.selectors == [ ":root" ] && rule.media.empty? }
    root.declarations.scan(/--([\w-]+)\s*:\s*([^;]+)/).to_h { |name, value| [ name, value.strip ] }
  end
end
