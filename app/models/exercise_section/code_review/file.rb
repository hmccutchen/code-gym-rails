ExerciseSection::CodeReview::File = Data.define(:path, :code, :changed) do
  def prompt_text = "File: #{path}\nChanged lines: #{changed.presence&.join(", ") || "none"}\n#{code}"
end
