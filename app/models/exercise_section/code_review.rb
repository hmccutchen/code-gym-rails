# Design notes: docs/code-notes/app/models/exercise_section/code_review.md
class ExerciseSection::CodeReview < ExerciseSection
  extend PlantedKey::Kind

  KEY_FIELDS = %w[issue why_it_matters fix].freeze

  MAX_SNIPPET_LINES = RealSource::MAX_LINES

  MAX_FILE_LINES = 15

  MAX_PATH_LENGTH = 120

  FILE_SLOTS = 1..3

  CHANGED_PART = "changed"

  FILE_PARTS = [ "path", "code", CHANGED_PART ].freeze

  FILE_FIELDS = (FILE_PARTS + %w[changed_lines]).freeze

  FILE_CODE_FIELDS = FILE_SLOTS.map { |number| "file_#{number}_code" }.freeze

  MULTI_FILE_RANGES = { "junior" => 1..1, "mid_level" => 2..2, "senior" => 2..3, "principal_engineer" => 2..3 }.freeze

  HIDDEN_KEY_LINE = PlantedKey.hidden_key_line(fields: %w[question scenario teaching_note diagram], before: "reads the snippet",
                                                quoted: "the code").freeze

  ANSWER_KEY_SCHEMA = <<~SCHEMA.chomp
    "answer_key": {
          "issue":          "string — a few sentences: what is wrong and where, quoting the code in backticks",
          "why_it_matters": "string — a few sentences: what goes wrong because of it in this code",
          "fix":            "string — a few sentences: a fix that works as written"
        }
  SCHEMA

  def self.file_range(files:, rung:)
    files == :multi ? MULTI_FILE_RANGES.fetch(rung, MULTI_FILE_RANGES.fetch("junior")) : 1..1
  end

  def self.day_file_range(plan:, difficulty:, skill_level:)
    file_range(files: plan.code_review_files, rung: difficulty.rung_for(self, skill_level: skill_level))
  end

  def self.key_context_fields = [ "snippet", "current_schema", *FILE_CODE_FIELDS ]

  def self.quoted_key_texts(key) = [ key&.dig("issue") ]

  def self.normalize_planted_key(section) = PlantedKey.fields(section[PlantedKey::FIELD], KEY_FIELDS)

  def self.refusal_codes = %w[snippet_missing snippet_too_long file_count_wrong file_incomplete file_too_long path_invalid
                              changed_lines_unresolved]

  def self.files(section)
    FILE_SLOTS.filter_map do |number|
      path, code, = file_parts(section, number)
      next unless usable_text?(path) && usable_text?(code)

      lines = section["file_#{number}_changed_lines"]
      File.new(path: path, code: code, changed: list_of?(lines, Integer) ? lines : [])
    end
  end

  NUMBERED_FILES_NOTE = "The page numbers each file's lines the way they are numbered here. " \
                        "The \"N | \" before each line is not part of the code, so never copy it into code you write."

  def self.files_context(section) = numbered_files(section)&.then { |files| "#{NUMBERED_FILES_NOTE}\n#{files}" }

  def self.numbered_files(section) = files(section).map(&:prompt_text).join("\n").presence
  private_class_method :numbered_files

  def self.judge_hidden_fields = FILE_SLOTS.flat_map { |number| FILE_FIELDS.map { |field| "file_#{number}_#{field}" } }

  def self.judge_attachment(section)
    files = numbered_files(section)
    "The section's files, every line numbered, with \"Changed lines\" naming the lines the page marks as the change:\n#{files}" if files
  end

  def self.reject_unusable!(section, language: nil, file_range: 1..1, **)
    if file_range.max == 1
      reject_unusable_snippet!(section)
      return drop_file_fields!(section)
    end

    raise ArgumentError, "missing keyword: :language" if language.nil?

    FILE_SLOTS.each { |number| reject_incomplete_file!(section, number) }
    shown = files(section)
    reject_wrong_file_count!(section, shown.size, file_range)
    reject_long_files!(shown)
    reject_invalid_paths!(shown)
    resolve_changed_lines!(section, language)
    drop_absent_files!(section)
  end

  def self.reject_unusable_snippet!(section)
    snippet = section["snippet"]
    refuse!("snippet_missing", "Code review returned no usable snippet") unless usable_text?(snippet)

    lines = shown_lines(snippet)
    return if lines <= MAX_SNIPPET_LINES

    refuse!("snippet_too_long", "Code review snippet runs #{lines} lines, past #{MAX_SNIPPET_LINES}")
  end

  def self.reject_incomplete_file!(section, number)
    path, code, changed = file_parts(section, number)
    given = [ path, code ].reject(&:nil?)
    complete = given.empty? || (given.size == 2 && given.all? { |text| usable_text?(text) })
    return if complete && (changed.nil? || list_of?(changed, String))

    refuse!("file_incomplete", "Code review file #{number} is incomplete or has a field of the wrong type")
  end

  def self.reject_wrong_file_count!(section, count, file_range)
    return if section["snippet"].nil? && file_range.cover?(count)

    refuse!("file_count_wrong", "Code review has #{count} complete files and #{section["snippet"].nil? ? 'no' : 'a'} snippet, " \
                                "where #{file_range.min} to #{file_range.max} files were asked for")
  end

  def self.reject_long_files!(shown)
    counts = shown.map { |file| shown_lines(file.code) }
    longest = counts.max.to_i
    refuse!("file_too_long", "A code review file runs #{longest} lines, past #{MAX_FILE_LINES}") if longest > MAX_FILE_LINES
    return if counts.sum <= MAX_SNIPPET_LINES

    refuse!("file_too_long", "Code review files run #{counts.sum} lines together, past #{MAX_SNIPPET_LINES}")
  end

  def self.reject_invalid_paths!(shown)
    longest = shown.map { |file| file.path.length }.max.to_i
    refuse!("path_invalid", "A code review path runs #{longest} characters, past #{MAX_PATH_LENGTH}") if longest > MAX_PATH_LENGTH
    refuse!("path_invalid", "A code review path holds a control character") if shown.any? { |file| file.path.match?(/[[:cntrl:]]/) }
    return if shown.map(&:path).uniq.size == shown.size

    refuse!("path_invalid", "Two code review files share a path")
  end

  def self.resolve_changed_lines!(section, language)
    resolved = FILE_SLOTS.to_h do |number|
      _, code, changed = file_parts(section, number)
      lines = usable_text?(code) ? Array(changed).filter_map { |quote| KeyQuote.line(code, quote, language: language) } : []
      [ number, lines.flat_map(&:to_a).uniq.sort ]
    end
    refuse!("changed_lines_unresolved", "No code review file has a changed line its quotes resolve to") if resolved.values.all?(&:empty?)

    resolved.each { |number, lines| section["file_#{number}_changed_lines"] = lines if usable_text?(section["file_#{number}_code"]) }
  end

  def self.drop_absent_files!(section)
    FILE_SLOTS.each do |number|
      path, code, = file_parts(section, number)
      FILE_FIELDS.each { |part| section.delete("file_#{number}_#{part}") } if path.nil? && code.nil?
    end
  end

  def self.drop_file_fields!(section)
    FILE_SLOTS.each { |number| FILE_FIELDS.each { |part| section.delete("file_#{number}_#{part}") } }
  end

  def self.file_parts(section, number) = FILE_PARTS.map { |part| section["file_#{number}_#{part}"] }

  def self.list_of?(value, type) = value.is_a?(Array) && value.all?(type)

  private_class_method :reject_unusable_snippet!, :reject_incomplete_file!, :reject_wrong_file_count!, :reject_long_files!,
                       :reject_invalid_paths!, :resolve_changed_lines!, :drop_absent_files!, :drop_file_fields!, :file_parts,
                       :list_of?

  def self.arrange!(section)
    section.delete("diagram") if files(section).any?
  end

  def self.diagrammable?
    true
  end

  def self.titled_label?
    false
  end

  def self.default_daily?
    true
  end

  def self.judge_task
    "Find the one planted issue in the snippet and say how to fix it."
  end

  def self.discovery?
    true
  end

  def self.code_fields
    [ "snippet", *FILE_CODE_FIELDS ]
  end

  def self.prose_fields
    %w[scenario question teaching_note]
  end

  # A RealSource excerpt's own instruction replaces the mode's toy line.
  def self.generation_guidance(vocabulary:, label:, mode: nil, artifact: nil, test_framework: nil, source: nil, rung: nil,
                               file_range: 1..1, code_style: nil, **)
    vocabulary_line = "- Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}"
    if file_range.max > 1
      return MultiFile.guidance(file_range: file_range, label: label, mode: mode, artifact: artifact, test_framework: test_framework,
                                rung: rung, code_style: code_style, vocabulary: vocabulary,
                                shared_lines: [ vocabulary_line, MultiFile::HIDDEN_KEY_LINE ])
    end

    [ source ? source.instruction : content_instruction(label, mode, artifact, test_framework), vocabulary_line, HIDDEN_KEY_LINE ].join("\n")
  end

  def self.content_instruction(label, mode, artifact, test_framework)
    case mode
    when :test_file
      "- The code_review snippet must be #{test_framework} #{label} test file — a realistic test file exhibiting one real test smell, same question shape (\"what's the issue here, and how would you fix it\")."
    when :schema_review
      "- The code_review snippet must be #{artifact}, ~10-15 lines, containing one planted data-modeling flaw. Same question shape as any other code_review (\"what's the issue here, and how would you fix it\") — the engineer reviews the proposed change, not prose about it."
    else
      "- The code_review snippet must be realistic #{label} code — not toy examples."
    end
  end
  private_class_method :content_instruction

  # Keep the snippet's language out of here: the instruction line above is its one authoritative statement.
  def self.schema_fragment(label:, file_range: 1..1, **)
    return MultiFile.schema_fragment(file_range: file_range, answer_key: ANSWER_KEY_SCHEMA) if file_range.max > 1

    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — what to find/fix",
          "snippet":  "string — ~10-15 lines, matching the code_review snippet instruction above",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "diagram":  "string — Mermaid source showing the structure this snippet describes, or an empty string if no diagram would help",
          #{ANSWER_KEY_SCHEMA}
        }
    SCHEMA
  end

  IMPROVED_CODE_FILES_LINE = "This section shows several files, so start each changed file's part of \"improved_code\" with a line " \
                             "\"File: <path>\", the path exactly as shown above, and leave out a file the fix doesn't change."

  def self.grading_note(section:, answer:)
    [ "Main point: the one planted issue — the defect in the snippet, the smell in the test file, or the flaw in the migration.\n" \
      "Essential pieces: why it is a problem in this code, and a fix that would work as written.",
      improved_code_files_line(section) ].compact.join("\n")
  end

  def self.walkthrough_note(section:) = improved_code_files_line(section).to_s

  def self.improved_code_files_line(section) = (IMPROVED_CODE_FILES_LINE if files(section).any?)
  private_class_method :improved_code_files_line

  def self.review_context(section:, answer:, rating:)
    [
      "Code Review question: #{section["question"]}",
      files_context(section) || "Code snippet: #{section["snippet"]}",
      current_schema_lines(section["current_schema"]),
      answer_lines(answer, rating)
    ].compact.join("\n")
  end

  def self.current_schema_lines(schema)
    return if schema.blank?

    <<~SCHEMA.chomp
      Current schema — the real table(s) as they stand today in db/schema.rb. The snippet is a new migration proposed against them, so a column or index already here is not part of the flaw and the answer does not need to add it:
      #{schema}
    SCHEMA
  end
  private_class_method :current_schema_lines
end
