require_relative "model_comparison"

# Writes a few concepts' Learn write-ups with today's prompt, or with a
# candidate prompt that adds a short lesson, and puts them side by side in one
# markdown file for a person to read. Read by script/compare_concept_lessons.rb
# only.
#
# Nothing shipped changes. The candidate prompt exists only inside this
# process's service object, the service writes no ApiUsage row, and nothing
# here creates or updates a ConceptReference: the reply is saved as JSON under
# tmp/, which git ignores.
class ConceptLessonComparison
  OUT_DIR = Rails.root.join("tmp/concept_lessons")
  VARIANTS = %w[current candidate].freeze

  # The hand-written target a variant is read against, between its markers.
  TARGETS = { "idempotency" => Rails.root.join("docs/lesson-shape-idempotency-target.md") }.freeze
  TARGET_PATTERN = /<!-- target:start -->\n(.+?)\n<!-- target:end -->/m

  # The candidate lesson's sections, in reading order, with the label each
  # takes in the markdown and the words the hand-written target uses for it.
  SECTIONS = {
    "definition"       => { label: "In one sentence", target: "In one sentence:" },
    "comparison"       => { label: "Everyday version", target: "Everyday version:" },
    "comparison_limit" => { label: "Where the comparison stops", target: "Where the comparison stops:" },
    "misunderstanding" => { label: "Common mix-up", target: "Common mix-up:" },
    "situations"       => { label: "When you run into it", target: "When you run into it:" },
    "habits"           => { label: "Habits, each with its catch", target: "Catch:" },
    "carry_question"   => { label: "Question to carry", target: "Question to carry:" },
    "quick_test"       => { label: "Quick test", target: "Quick test:" }
  }.freeze

  LESSON_WORD_TARGET = 350

  # The current write-up's prose, in the order the Learn page shows it. Code
  # and the worked example are left out of the checks: the worked example
  # mixes code fragments with its prose, so its words would count code.
  CURRENT_PROSE_FIELDS = %w[tagline explanation guide_plain_language guide_pitfalls senior_lens].freeze
  CURRENT_FIELDS = %w[tagline explanation guide_plain_language code_example guide_worked_example
                      guide_pitfalls senior_lens ladder_junior ladder_senior ladder_principal_engineer].freeze

  # Where the candidate block goes in today's prompt. If the prompt is
  # reworded so either anchor is gone, the candidate refuses to run rather
  # than sending a prompt nobody has read.
  INSTRUCTION_ANCHOR = "Return JSON matching this schema exactly:"
  SCHEMA_END = /\n\}\n?\z/

  CANDIDATE_INSTRUCTION = <<~TEXT.freeze
    Then write a short lesson for someone reading this concept on a phone, under
    "lesson". Every key in it is optional: leave a key out when it does not fit
    this concept, and never pad one to fill it. Keep the whole lesson under about
    #{LESSON_WORD_TARGET} words, in plain prose with no code.
    - definition: one sentence saying what the concept is.
    - comparison: an everyday comparison that maps onto the concept exactly.
    - comparison_limit: one sentence saying where that comparison stops working. Include it whenever you include comparison.
    - misunderstanding: the most common wrong idea about this concept, and what is true instead.
    - situations: two to four concrete situations where an engineer runs into it, each one short.
    - habits: one to four small habits or fixes. Each carries "catch": the real limit or cost of that habit, which the reader sees directly after it.
    - carry_question: one question the reader can ask about their own work.
    - quick_test: a quick way to check their own code or plan for it.
    The plain-language standard above applies to the lesson as well as the guide fields.

  TEXT

  CANDIDATE_SCHEMA = <<~TEXT.chomp.freeze
    ,
      "lesson": {
        "definition":       "string",
        "comparison":       "string",
        "comparison_limit": "string",
        "misunderstanding": "string",
        "situations":       ["string"],
        "habits":           [{ "habit": "string", "catch": "string" }],
        "carry_question":   "string",
        "quick_test":       "string"
      }
    }
  TEXT

  def self.candidate_prompt(prompt)
    unless prompt.include?(INSTRUCTION_ANCHOR) && prompt.match?(SCHEMA_END)
      raise ArgumentError, "build_concept_reference_prompt no longer has the anchors the candidate prompt is inserted at"
    end

    prompt.sub(INSTRUCTION_ANCHOR, "#{CANDIDATE_INSTRUCTION}#{INSTRUCTION_ANCHOR}").sub(SCHEMA_END, "#{CANDIDATE_SCHEMA}\n")
  end

  # A concept name, or BUCKET/CONCEPT where the concept sits in more than one
  # bucket. A bare name takes its first bucket in ConceptBucket order.
  def self.resolve(argument)
    bucket, concept = argument.include?("/") ? argument.split("/", 2) : [ nil, argument ]
    buckets = DailyExercise::LANGUAGES + ConceptBucket::LANGUAGE_INDEPENDENT
    bucket ||= buckets.find { |candidate| ConceptBucket.vocabulary_for(candidate).include?(concept) }

    unless bucket && buckets.include?(bucket) && ConceptBucket.vocabulary_for(bucket).include?(concept)
      raise ArgumentError, "#{argument} is in no vocabulary"
    end

    [ bucket, concept ]
  end

  # The prose a variant's checks read, and which of its sections are present.
  def self.lesson_for(variant, reference)
    if variant == "candidate"
      lesson = reference["lesson"].is_a?(Hash) ? reference["lesson"] : {}
      present = SECTIONS.keys.select { |key| lesson[key].present? }
      { prose: present.map { |key| section_text(lesson[key]) }.join(" "), sections: present }
    else
      present = CURRENT_FIELDS.select { |field| reference[field].present? }
      { prose: CURRENT_PROSE_FIELDS.filter_map { |field| reference[field].presence }.join(" "), sections: present }
    end
  end

  def self.path_for(dir, variant, bucket, concept)
    dir.join(variant, "#{bucket}-#{concept}.json")
  end

  # Every pair either variant has saved, so a run for one concept keeps the
  # others in the report. A bucket name never holds a hyphen, so the first
  # one separates it from the concept; a file that no longer names a
  # vocabulary concept is left out.
  def self.saved_pairs(dir)
    VARIANTS.flat_map { |variant| dir.glob("#{variant}/*.json") }
            .map { |path| path.basename(".json").to_s.split("-", 2) }
            .select { |bucket, concept| AiService::LANGUAGE_CONFIG.key?(bucket) && ConceptBucket.vocabulary_for(bucket).include?(concept) }
            .uniq.sort
  end

  def self.target_for(concept)
    text = TARGETS[concept]&.read&.[](TARGET_PATTERN, 1)
    return unless text

    { text: text, sections: SECTIONS.select { |_key, section| text.include?(section[:target]) }.keys }
  end

  def self.section_text(value)
    case value
    when Array then value.map { |entry| entry.is_a?(Hash) ? "#{entry['habit']} Catch: #{entry['catch']}" : entry.to_s }.join(" ")
    else value.to_s
    end
  end

  def self.failures(checks)
    [ ("placeholder phrases: #{checks[:placeholder_phrases].join(', ')}" if checks[:placeholder_phrases].any?),
      ("every sentence opens the same way" if checks[:same_opening]) ].compact
  end

  def self.flags(checks)
    [ ("over #{LESSON_WORD_TARGET} words" if checks[:words] > LESSON_WORD_TARGET),
      ("#{checks[:contrasts].size} not-X-but-Y" if checks[:contrasts].any?),
      ("#{checks[:long_sentences].size} long sentence(s)" if checks[:long_sentences].any?),
      ("#{checks[:exclamation_points]} exclamation point(s)" if checks[:exclamation_points].positive?),
      ("#{checks[:pleases]} please(s)" if checks[:pleases].positive?) ].compact
  end

  def initialize(api_key:, candidate:, out: $stdout, dir: OUT_DIR)
    @api_key = api_key
    @variant = candidate ? "candidate" : "current"
    @out = out
    @dir = dir
  end

  def run(arguments)
    pairs = arguments.map { |argument| self.class.resolve(argument) }.uniq
    pairs.each { |bucket, concept| write_variant(bucket, concept) }
    write_comparison(pairs | self.class.saved_pairs(@dir))
  end

  private

  def write_variant(bucket, concept)
    usage = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reference = service(usage).generate_concept_reference(nil, concept, bucket)
    record = { "reference" => reference, "usage" => usage.each_with_object(Hash.new(0)) { |call, total| call.each { |key, count| total[key] += count } },
               "seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) }
    save(bucket, concept, record)
    print_row(bucket, concept, record)
  rescue AiService::Error, ArgumentError => e
    save(bucket, concept, { "error" => "#{e.class}: #{e.message}" })
    @out.puts format("%-36s %-10s error: %s", "#{bucket}/#{concept}", @variant, e.class)
  end

  # The production route for this purpose on Claude, with usage kept in
  # memory instead of written as an ApiUsage row. The candidate variant swaps
  # the prompt for this object only.
  def service(usage)
    candidate = @variant == "candidate"

    Class.new(ClaudeService) do
      define_method(:log_usage) do |_user, result, purpose:|
        usage << { "tokens_in" => result[:input_tokens].to_i, "tokens_out" => result[:output_tokens].to_i }
      end
      define_method(:build_concept_reference_prompt) do |concept, config|
        prompt = super(concept, config)
        candidate ? ConceptLessonComparison.candidate_prompt(prompt) : prompt
      end
      private :log_usage, :build_concept_reference_prompt
    end.new(@api_key)
  end

  def save(bucket, concept, record)
    path = self.class.path_for(@dir, @variant, bucket, concept)
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.pretty_generate(record))
  end

  def print_row(bucket, concept, record)
    lesson = self.class.lesson_for(@variant, record["reference"])
    checks = PlainLanguageChecks.report(lesson[:prose])
    @out.puts format("%-36s %-10s %4d words  sections: %s  failures: %s  flags: %s  %ss  $%.4f",
                     "#{bucket}/#{concept}", @variant, checks[:words], lesson[:sections].join(","),
                     self.class.failures(checks).presence&.join(";") || "none",
                     self.class.flags(checks).presence&.join(";") || "none",
                     record["seconds"], cost(record["usage"]))
  end

  def cost(usage)
    usage ||= {}
    price = ModelComparison::LIST_PRICE_PER_MILLION.fetch(ClaudeService::DEFAULT_ROUTE[:model])
    (usage["tokens_in"].to_i * price[:input] + usage["tokens_out"].to_i * price[:output]) / 1_000_000.0
  end

  def write_comparison(pairs)
    path = @dir.join("comparison.md")
    FileUtils.mkdir_p(@dir)
    path.write(ComparisonDocument.new(pairs, dir: @dir).render)
    @out.puts "\nWrote #{path.relative_path_from(Rails.root)}"
  end

  # The markdown a reader opens: the checklist, then each concept's variants
  # one after another, each followed by its checks.
  class ComparisonDocument
    CHECKLIST = <<~MD.freeze
      ## Reviewer checklist

      For each candidate lesson:

      - [ ] Does the everyday comparison map exactly onto the concept, part for part?
      - [ ] Where does the comparison break, and does "Where the comparison stops" say so?
      - [ ] Is each "catch" a real limit or cost of its habit, not a restatement of it?
      - [ ] Is anything padded: a section that would read better left out?
      - [ ] Does it fit a phone screen: about #{LESSON_WORD_TARGET} words, code excluded?

      The checks under each lesson cover only the plain-language rules code can
      check. Jargon, active voice, rhythm and forced cleverness need a reader.
      Failures are rules plain text never needs; flags point at sentences to read.
    MD

    def initialize(pairs, dir:)
      @pairs = pairs
      @dir = dir
    end

    def render
      [ "# Concept lesson comparison", "Generated #{Time.current.utc.iso8601} by script/compare_concept_lessons.rb.",
        CHECKLIST, *@pairs.map { |bucket, concept| concept_section(bucket, concept) } ].join("\n\n")
    end

    private

    def concept_section(bucket, concept)
      parts = [ "## #{concept} (#{bucket})" ]
      VARIANTS.each { |variant| parts << variant_section(variant, bucket, concept) }
      if (target = ConceptLessonComparison.target_for(concept))
        parts << titled("Hand-written target", target[:text], target[:sections], target[:text])
      end
      parts.join("\n\n")
    end

    def variant_section(variant, bucket, concept)
      path = ConceptLessonComparison.path_for(@dir, variant, bucket, concept)
      title = "#{variant.capitalize} lesson"
      return "### #{title}\n\nNot run yet. #{command_hint(variant)}" unless path.exist?

      record = JSON.parse(path.read)
      return "### #{title}\n\nThe last run failed: #{record['error']}" if record["error"]

      reference = record["reference"]
      lesson = ConceptLessonComparison.lesson_for(variant, reference)
      body = variant == "candidate" ? candidate_body(reference) : current_body(reference)
      titled(title, body, lesson[:sections], lesson[:prose])
    end

    def titled(title, body, sections, prose)
      "### #{title}\n\n#{body}\n\n#{checks_block(sections, prose)}"
    end

    def command_hint(variant)
      flag = variant == "candidate" ? " --candidate" : ""
      "Run `bin/rails runner script/compare_concept_lessons.rb#{flag} CONCEPT ...`."
    end

    def current_body(reference)
      CURRENT_FIELDS.filter_map do |field|
        value = reference[field].presence or next
        field == "code_example" ? "**#{field}**\n\n```\n#{value}\n```" : "**#{field}**\n\n#{value}"
      end.join("\n\n")
    end

    # The fields kept from today's prompt are folded away, so the new
    # sections read first.
    def candidate_body(reference)
      lesson = reference["lesson"].is_a?(Hash) ? reference["lesson"] : {}
      sections = SECTIONS.filter_map do |key, section|
        value = lesson[key].presence or next
        "**#{section[:label]}**\n\n#{markdown_value(value)}"
      end
      sections = [ "_The reply had no lesson._" ] if sections.empty?

      "#{sections.join("\n\n")}\n\n<details><summary>The fields kept from today's prompt, from the same call</summary>\n\n" \
        "#{current_body(reference)}\n\n</details>"
    end

    def markdown_value(value)
      return value.to_s unless value.is_a?(Array)

      value.map do |entry|
        entry.is_a?(Hash) ? "- #{entry['habit']} Catch: #{entry['catch']}" : "- #{entry}"
      end.join("\n")
    end

    def checks_block(sections, prose)
      checks = PlainLanguageChecks.report(prose)
      [ "**Checks**", "",
        "- Words: #{checks[:words]} (target under #{LESSON_WORD_TARGET})",
        "- Sections present: #{sections.join(', ').presence || 'none'}",
        "- Failures: #{ConceptLessonComparison.failures(checks).join('; ').presence || 'none'}",
        "- Flags: #{ConceptLessonComparison.flags(checks).join('; ').presence || 'none'}",
        *checks[:contrasts].map { |sentence| "  - not-X-but-Y: #{sentence}" },
        *checks[:long_sentences].map { |sentence| "  - long: #{sentence}" } ].join("\n")
    end
  end
end
