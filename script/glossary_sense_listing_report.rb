require "json"

# Lists every match of a key or form that is new since the base words, so a wrong-sense match can be seen in context.
class GlossarySenseListingReport
  CONTEXT = 20

  def self.read_words(path)
    File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
  end

  def self.read_rows(path)
    File.foreach(path).select { |line| line.start_with?("{") }.map { |line| JSON.parse(line) }.reject { |row| row["source"] == "counts" }
  end

  def initialize(rows, base_words:, terms: Glossary::TERMS, forms: Glossary::FORMS, pattern_for: Glossary.method(:pattern_for), key_for: Glossary.method(:key_for))
    @rows = rows
    @new_words = (terms.keys + forms.values.flatten) - base_words
    @pattern = pattern_for.call(@new_words.to_h { |word| [ word, nil ] })
    @key_for = key_for
  end

  def groups
    @rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, found|
      row["text"].to_s.scan(@pattern) { found[@key_for.call($~[0])] << line_for(row, $~) }
    end
  end

  def print(out = $stdout)
    found = groups
    found.sort_by { |key, lines| [ -lines.size, key ] }.each do |key, lines|
      out.puts "== #{key} (#{lines.size})"
      lines.each { |line| out.puts "  #{line}" }
    end
    out.puts "== total matches: #{found.values.sum(&:size)} across #{found.size} keys"
  end

  private

  def line_for(row, match)
    "#{row['source']} #{row['id']} #{row['field']}: …#{before(row['text'], match)}[#{match[0]}]#{row['text'][match.end(0), CONTEXT]}…"
  end

  def before(text, match)
    text[[ match.begin(0) - CONTEXT, 0 ].max...match.begin(0)]
  end
end
