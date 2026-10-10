# CodeHighlight puts each line in its own .code-line with no newline, so join the lines to read the text.
module CodeBlockHelpers
  def code_block_text(code)
    code.css(".code-line").map { |line| line.text == "\n" ? "" : line.text }.join("\n")
  end
end

RSpec.configure do |config|
  config.include CodeBlockHelpers
end
