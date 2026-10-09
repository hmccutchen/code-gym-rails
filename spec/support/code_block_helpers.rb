# CodeHighlight renders each source line as its own .code-line, with no
# newline between them, so a block's text reads back by joining its lines.
module CodeBlockHelpers
  def code_block_text(code)
    code.css(".code-line").map { |line| line.text == "\n" ? "" : line.text }.join("\n")
  end
end

RSpec.configure do |config|
  config.include CodeBlockHelpers
end
