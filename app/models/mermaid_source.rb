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

  HEADER = /\A(?:flowchart|graph)(?:[ \t]+(?:TD|TB|BT|LR|RL))?[ \t]*\z/
  REFUSED_STATEMENT = /\A[ \t]*(?:classDef|class|style|linkStyle|click)\b/

  def self.usable?(source)
    return false unless source.is_a?(String)

    text = source.strip
    return false unless text.length.between?(1, MAX_LENGTH)
    return false if text.include?("%%{")

    lines = text.lines(chomp: true)
    lines.first.match?(HEADER) && lines.none? { |line| line.match?(REFUSED_STATEMENT) }
  end
end
