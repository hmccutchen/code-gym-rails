ExerciseSection::CodeReview::File = Data.define(:path, :code, :changed) do
  def prompt_text = "File: #{path}\nChanged lines: #{changed.presence&.join(", ") || "none"}\n#{numbered_code}"

  def numbered_code
    lines = code.lines(chomp: true)
    width = lines.size.to_s.length
    lines.each.with_index(1).map { |line, number| numbered_line(line, number.to_s.rjust(width)) }.join("\n")
  end

  private

  def numbered_line(line, number) = line.empty? ? "#{number} |" : "#{number} | #{line}"
end
