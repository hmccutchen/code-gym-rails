# Which Mermaid source the app hands to the renderer. The generation prompt
# asks for `flowchart TD` or `graph LR` with no styling, class definitions or
# click handlers, and nothing else is rendered: Mermaid's published XSS and
# CSS-injection bugs sit in other diagram types, config directives and
# class and style definitions, so refusing them keeps a future Mermaid bug in
# that surface from reaching a page. Ingest drops a source that fails this,
# and the view checks it again for rows stored before the rule existed.
module MermaidSource
  # The prompt asks for at most 8 nodes with short labels, which lands well
  # under half this, so the bound rejects runaway output without rejecting
  # anything actually asked for.
  MAX_LENGTH = 1_000

  HEADER = /\A(?:flowchart|graph)(?:[ \t]+(?:TD|TB|BT|LR|RL))?\z/
  REFUSED_STATEMENT = /\A(?:classDef|class|style|linkStyle|click)\b/
  # Mermaid ends a statement at a semicolon as well as a line break. A
  # semicolon inside a quoted label also splits here, which can only refuse
  # more, never less.
  STATEMENT_BREAK = /[;\n]/
  # Mermaid's lexer treats every JavaScript whitespace character as a space,
  # including a no-break space, a BOM and a line separator, which Ruby's strip
  # leaves in place. A statement behind one would slip past REFUSED_STATEMENT,
  # so any whitespace or invisible formatting character beyond space, tab and
  # line breaks refuses the whole source.
  UNEXPECTED_SPACING = /[\p{Space}\p{Cf}&&[^ \t\n\r]]/

  def self.usable?(source)
    return false unless source.is_a?(String)

    text = source.strip
    return false unless text.length.between?(1, MAX_LENGTH)
    return false if text.include?("%%{") || text.match?(UNEXPECTED_SPACING)

    statements = text.split(STATEMENT_BREAK).map(&:strip)
    statements.first.match?(HEADER) && statements.none? { |statement| statement.match?(REFUSED_STATEMENT) }
  end
end
