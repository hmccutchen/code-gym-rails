require "rails_helper"

RSpec.describe MermaidSource do
  it "accepts the flowchart and graph headers the prompt asks for" do
    [ "flowchart TD\n  A[Job] --> B[(DB)]", "graph LR\n  A --> B", "flowchart\n  A --> B",
      "  flowchart TB  \n  A[\"Order service\"] --> B", "flowchart TD;A --> B", "graph LR\n  A[\"x; y\"] --> B" ].each do |source|
      expect(described_class.usable?(source)).to be(true), source
    end
  end

  it "refuses any other diagram type" do
    [ "sequenceDiagram\n  A->>B: hi", "architecture-beta\n  service a(server)[A]", "stateDiagram-v2\n  [*] --> A",
      "classDiagram\n  A <|-- B", "gantt\n  title x", "xychart-beta\n  bar [1, 2]" ].each do |source|
      expect(described_class.usable?(source)).to be(false), source
    end
  end

  it "refuses config directives and front matter" do
    [ "%%{init: {'theme': 'base'}}%%\nflowchart TD\n  A --> B", "flowchart TD\n  %%{init: {}}%%\n  A --> B",
      "---\nconfig:\n  theme: base\n---\nflowchart TD\n  A --> B" ].each do |source|
      expect(described_class.usable?(source)).to be(false), source
    end
  end

  it "refuses class, style and click statements" do
    [ "classDef hot fill:#f00", "class A hot", "style A fill:#f00", "linkStyle 0 stroke:#f00",
      "click A \"https://example.com\"" ].each do |statement|
      expect(described_class.usable?("flowchart TD\n  A --> B\n  #{statement}")).to be(false), statement
    end
  end

  # Mermaid ends a statement at a semicolon too, so a refused statement after
  # one is still a statement.
  it "refuses class, style and click statements that follow a semicolon" do
    [ "flowchart TD\n  A --> B;style A fill:#f00", "flowchart TD\n  A --> B; classDef hot fill:#f00",
      "graph TD;class A hot", "flowchart TD;click A \"https://example.com\"" ].each do |source|
      expect(described_class.usable?(source)).to be(false), source
    end
  end

  # Mermaid reads each of these as a space, so a statement behind one is still
  # a statement; Ruby's strip removes none of them.
  it "refuses whitespace and invisible formatting characters beyond space, tab and line breaks" do
    [ "\u00A0", "\uFEFF", "\u2028", "\u3000", "\v", "\f", "\u2003", "\u200B" ].each do |character|
      source = "flowchart TD\n  A --> B\n#{character}style A fill:#f00"
      expect(described_class.usable?(source)).to be(false), character.inspect
    end
    expect(described_class.usable?("flowchart TD\n  A[\"Order\u00A0service\"] --> B")).to be(false)
  end

  it "accepts tabs and Windows line endings" do
    expect(described_class.usable?("flowchart TD\r\n\tA --> B\r\n")).to be(true)
  end

  it "refuses blank, oversized and non-string sources" do
    [ nil, 42, [ "flowchart TD" ], "", "   ", ";", ";;\n;", "\n;", "flowchart TD\n#{'x' * described_class::MAX_LENGTH}" ].each do |source|
      expect(described_class.usable?(source)).to be(false), source.inspect
    end
  end
end
