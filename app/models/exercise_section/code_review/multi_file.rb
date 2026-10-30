module ExerciseSection::CodeReview::MultiFile
  HIDDEN_KEY_LINE = ExerciseSection::CodeReview.hidden_key_line(fields: %w[question scenario teaching_note], shown: "the files").freeze

  SUBTLETY = {
    "mid_level"          => "- Nothing in the question or the code points at the problem; reading the second file closely finds it.",
    "senior"             => "- The broken assumption sits in a file the change didn't touch.",
    "principal_engineer" => "- The broken assumption is implicit, such as a callback, a default or a database constraint, and every fix has a cost on each side."
  }.freeze

  def self.guidance(file_range:, label:, mode:, artifact:, test_framework:, rung:, code_style:, vocabulary:, shared_lines:)
    [
      shape_line(mode, file_count(file_range), label, artifact, test_framework),
      SUBTLETY[rung],
      "- Each file shows at most #{ExerciseSection::CodeReview::MAX_FILE_LINES} lines, and all the files at most " \
        "#{ExerciseSection::CodeReview::MAX_SNIPPET_LINES} lines together.",
      "- Every change adds or edits at least one line, and \"file_N_changed\" lists each line the change added or edited in that file. " \
        "Show a removed call through the line that changed around it, never as a line that is simply gone.",
      "- Copy each changed line exactly as it reads in its file, and make sure it appears only once in its file, so it marks one line.",
      ("- Write each file in #{code_style}." if code_style),
      *shared_lines,
      ("- An `authorization` flaw here is a broken contract between files, never an injection or mass-assignment exploit." if
        vocabulary.include?("authorization"))
    ].compact.join("\n")
  end

  def self.file_count(file_range) = "#{file_range.minmax.uniq.join(" or ")} files"

  def self.shape_line(mode, count, label, artifact, test_framework)
    case mode
    when :test_file
      "- The code_review section shows #{count} after one change: the changed #{label} code and #{test_framework} test file for it, plus at most one more file. Plant one problem in how they fit together: the test still passes but no longer checks what the change broke, or it still asserts the old contract."
    when :schema_review
      "- The code_review section shows #{count} after one change: #{artifact}, and the model or query code that depends on it. Plant one data-modeling problem in how they fit together: the model or query assumes something the schema change took away or never added."
    else
      "- The code_review section shows #{count} of realistic #{label} code as they stand after one change, such as a changed method or model and its caller, or a controller and the policy or service it relies on. Plant one problem in how they fit together: a file the change didn't touch assumed something the change broke."
    end
  end

  def self.schema_fragment(file_range:, answer_key:)
    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — what to review, never where the problem is",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing and what the change is for",
          #{(1..file_range.max).map { |number| file_fields(number, optional: number > file_range.min) }.join(",\n    ")},
          #{answer_key}
        }
    SCHEMA
  end

  def self.file_fields(number, optional:)
    only = optional ? " (only when this change needs a file #{number}; otherwise leave out every file_#{number} field)" : ""
    [
      %("file_#{number}_path": "string — a realistic path for file #{number}#{only}"),
      %("file_#{number}_code": "string — file #{number}'s code after the change, at most #{ExerciseSection::CodeReview::MAX_FILE_LINES} lines"),
      %("file_#{number}_changed": ["string — each line this change added or edited in file #{number}, copied exactly"])
    ].join(",\n    ")
  end

  private_class_method :file_count, :shape_line, :file_fields
end
