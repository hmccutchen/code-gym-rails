ExerciseSection::CodeReview::File = Data.define(:path, :code, :changed) do
  def prompt_text = "File: #{path}\nChanged lines: #{changed.presence&.join(", ") || "none"}\n#{numbered_code}"

  def numbered_code
    lines = code.lines(chomp: true)
    width = lines.size.to_s.length
    lines.each.with_index(1).map { |line, number| "#{number.to_s.rjust(width)} | #{line}".rstrip }.join("\n")
  end
end
