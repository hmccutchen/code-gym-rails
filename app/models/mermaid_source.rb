# Only plain flowcharts render, since Mermaid's known XSS bugs live in other diagram types, directives and styles.
module MermaidSource
  # Well over what an 8-node prompt produces, so it rejects only runaway output.
  MAX_LENGTH = 1_000

  HEADER = /\A(?:flowchart|graph)(?:[ \t]+(?:TD|TB|BT|LR|RL))?\z/
  REFUSED_STATEMENT = /\A(?:classDef|class|style|linkStyle|click)\b/
  # Mermaid also ends a statement at a semicolon; splitting inside a quoted label only refuses more.
  STATEMENT_BREAK = /[;\n]/
  # Mermaid treats these as spaces but Ruby's strip doesn't, so a statement behind one could slip past REFUSED_STATEMENT.
  UNEXPECTED_SPACING = /[\p{Space}\p{Cf}&&[^ \t\n\r]]/

  def self.usable?(source)
    return false unless source.is_a?(String)

    text = source.strip
    return false unless text.length.between?(1, MAX_LENGTH)
    return false if text.include?("%%{") || text.match?(UNEXPECTED_SPACING)

    header, *body = text.split(STATEMENT_BREAK).map(&:strip)
    header.to_s.match?(HEADER) && body.none? { |statement| statement.match?(REFUSED_STATEMENT) }
  end
end
