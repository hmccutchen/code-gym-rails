# Design notes: docs/code-notes/app/models/worked_example.md
module WorkedExample
  Part = Data.define(:kind, :text)

  FENCE = /^```[^\n]*\n(.*?)^```[ \t]*$/m
  PARAGRAPH_BREAK = /\n[ \t]*\n/
  SENTENCE_END = /[.!?]["')\]]?\z/
  COMMENT_START = %r{\A(#|//|--)}
  CODE_LINE_END = /[{};]\z/
  INDENTED = /\A[ \t]+\S/
  CODE_TOKEN = /\w[.(]\w|\w\(|=/

  def self.parts(text)
    pieces = text.to_s.split(FENCE).each_with_index.flat_map do |chunk, index|
      index.odd? ? [ Part.new(kind: :code, text: chunk.chomp) ] : paragraphs(chunk)
    end
    merge(pieces)
  end

  def self.paragraphs(chunk)
    chunk.split(PARAGRAPH_BREAK).map { |paragraph| paragraph.sub(/\A\n+/, "").rstrip }.reject(&:blank?).map do |paragraph|
      Part.new(kind: prose?(paragraph) ? :prose : :code, text: paragraph)
    end
  end

  def self.prose?(paragraph)
    code_shaped = paragraph.lines.any? do |line|
      line.match?(INDENTED) || line.lstrip.match?(COMMENT_START) || line.rstrip.match?(CODE_LINE_END)
    end
    !code_shaped && (paragraph.match?(SENTENCE_END) || !paragraph.match?(CODE_TOKEN))
  end

  def self.merge(pieces)
    pieces.slice_when { |before, after| before.kind != after.kind }.map do |run|
      Part.new(kind: run.first.kind, text: run.map(&:text).join("\n\n"))
    end
  end
  private_class_method :paragraphs, :prose?, :merge
end
