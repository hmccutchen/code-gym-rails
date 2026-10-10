# Blocks persist in correct order, so a correct answer is the identity permutation and grading never asks the AI.
class ExerciseSection::ParsonsProblem < ExerciseSection
  ANSWER_PREFIX = "order:".freeze

  # Long enough that guessing a token isn't worth trying, short enough to read in a DOM inspector.
  TOKEN_LENGTH = 16

  class << self
    def improved_code?
      false
    end

    # Rolled once at ingest and persisted so every view shows the same scramble; never the identity, which is pre-solved.
    def arrange!(section)
      return unless section["blocks"].is_a?(Array)

      identity = (0...section["blocks"].size).to_a
      order    = identity.shuffle
      order    = identity.shuffle while order == identity && identity.size > 1
      section["display_order"] = order
    end

    # Replaces whatever the grader returned; nil without blocks, which would otherwise read as a perfect score.
    def fixed_rating(section:, answer:)
      blocks = Array(section["blocks"])
      return if blocks.empty?

      grade(submitted_order(answer, blocks.size), blocks.size)[:rating]
    end

    # Opaque so sorting by it can't solve the puzzle; signs the problem too, since regeneration reuses the exercise row.
    def block_token(block_id, exercise:, key:, section_data:)
      OpenSSL::HMAC.hexdigest(
        "SHA256", Rails.application.secret_key_base,
        "parsons:#{exercise&.id}:#{key}:#{problem_digest(section_data)}:#{block_id}"
      ).first(TOKEN_LENGTH)
    end

    # JSON, not a join: provider blocks can contain any separator, so a join lets two puzzles share a digest.
    def problem_digest(section_data)
      OpenSSL::Digest::SHA256.hexdigest(
        Array(section_data&.dig("blocks")).map(&:to_s).to_json
      ).first(TOKEN_LENGTH)
    end

    # Refuses an order these tokens can't account for; accepting "order:0,1,2" would hand over the answer the tokens hide.
    def decode_answer(value, exercise: nil, key: nil, section_data: nil)
      count = Array(section_data&.dig("blocks")).size
      text  = value.to_s
      return value if count.zero? || !text.start_with?(ANSWER_PREFIX)

      tokens = token_ids(exercise: exercise, key: key, section_data: section_data)
      ids    = text.delete_prefix(ANSWER_PREFIX).split(",").map { |t| tokens[t.strip] }
      return if ids.any?(&:nil?)

      ANSWER_PREFIX + ids.join(",")
    end

    # Rendering the stored positional order beside the tokens would reveal the token-to-id mapping.
    def token_answer(answer:, exercise:, key:, section_data:)
      ids = submitted_order(answer, Array(section_data&.dig("blocks")).size)
      return "" if ids.empty?

      ANSWER_PREFIX + ids.map { |id| block_token(id, exercise: exercise, key: key, section_data: section_data) }.join(",")
    end

    def token_ids(exercise:, key:, section_data:)
      count = Array(section_data&.dig("blocks")).size
      (0...count).to_h { |id| [ block_token(id, exercise: exercise, key: key, section_data: section_data), id ] }
    end

    def judge_task
      "Arrange the blocks into the working order."
    end

    def discovery?
      true
    end

    # A positional diff can't grade concepts with no right or wrong order; they have other hosts (annotate_retention_concept).
    def excluded_vocabulary_keys
      [ :data_modeling, :domain_modeling, :meta_skill, :code_smell, :oo_design, :module_design,
        :silent_correctness ]
    end

    def answer_partial
      "responses/answers/parsons_problem"
    end

    def answered?(value, section_data = nil)
      blocks = Array(section_data&.dig("blocks"))
      submitted_order(value, blocks.size).any?
    end

    # Incomplete attempts still need strict grading and lenient replay, though they don't count as completed work.
    def answer_for(value, _section_data = nil)
      value.presence
    end

    def generation_guidance(vocabulary:, label:, **)
      <<~GUIDANCE.chomp
        - The third section is a PARSONS PROBLEM: return "blocks" as 5 to 8 short code blocks IN THE CORRECT FINAL ORDER — the app shuffles them for display, you must never shuffle them yourself. Each block should be one coherent unit (a full line, or a short logically-grouped set of lines) — never a single token or a bare punctuation mark, since reordering individual tokens is busywork rather than the exercise.
        - Choose the parsons_problem concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
      GUIDANCE
    end

    def schema_fragment(label:)
      <<~SCHEMA.chomp
        "parsons_problem": {
            "title":    "string",
            "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
            "question": "string — e.g. 'Arrange these blocks into the correct working solution'",
            "blocks":   ["string — one logical line or short cohesive group of lines, IN THE CORRECT FINAL ORDER", "string — the next block in correct order", "... (5-8 blocks total)"],
            "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
            "concept": "string — exactly one concept from the provided vocabulary"
          }
      SCHEMA
    end

    # Returns [] for a malformed answer so grading reads it as all misplaced instead of raising.
    def parse_order(answer)
      text = answer.to_s
      return [] unless text.start_with?(ANSWER_PREFIX)

      text.delete_prefix(ANSWER_PREFIX).split(",").filter_map { |s| Integer(s, exception: false) }
    end

    # Saved orders are free-form params; a partial order would drop blocks and get persisted back by the next autosave.
    def normalize_order(ids, block_count)
      return [] unless ids.size == block_count && ids.uniq.size == block_count
      return [] unless ids.all? { |id| valid_id?(id, block_count) }

      ids
    end

    def valid_id?(id, block_count)
      id.is_a?(Integer) && id >= 0 && id < block_count
    end

    # Use this, not parse_order: "order:0,1,2,3,4,999" parses to a list whose prefix is the perfect identity order.
    def submitted_order(answer, block_count)
      normalize_order(parse_order(answer), block_count)
    end

    def initial_order(answer:, display_order:, block_count:)
      [ parse_order(answer), Array(display_order) ]
        .filter_map { |ids| normalize_order(ids, block_count).presence }
        .first || (0...block_count).to_a
    end

    # Normalizes first so a valid prefix plus garbage can't grade as exact; no `when 1`, since one lone misplaced block is impossible.
    def grade(submitted_ids, block_count)
      submitted_ids = normalize_order(submitted_ids, block_count)
      padded        = Array.new(block_count) { |i| submitted_ids[i] }
      mismatches    = padded.each_index.count { |i| padded[i] != i }

      rating =
        case mismatches
        when 0 then "strong"
        when 2 then "solid"
        else mismatches <= (block_count / 2.0).ceil ? "developing" : "beginner"
        end

      { mismatches: mismatches, rating: rating }
    end

    # No answer line: the order is already graded in Ruby, and "order:2,1" means nothing to the reviewer as prose.
    def review_context(section:, answer:, rating:)
      <<~CONTEXT.chomp
        Parsons Problem (#{section["title"]}): #{section["question"]}
        Their self-rating: #{rating.presence || '(none given)'}
      CONTEXT
    end

    # A section can resolve with no blocks; then skip grading instead of claiming a verified "0 out of place".
    def grading_note(section:, answer:)
      blocks = Array(section["blocks"])

      if blocks.empty?
        return <<~UNVERIFIED.chomp
          This section's blocks are missing from the stored exercise, so the submitted ordering CANNOT be verified. Do not state or imply how many blocks were misplaced, and do not rate this section's correctness — say only that the exercise data is unavailable.
          For this section "improved_code" must be an empty string.
        UNVERIFIED
      end

      submitted = submitted_order(answer, blocks.size)

      <<~PARSONS.chomp
        Correct blocks, in order: #{blocks.each_with_index.map { |b, i| "#{i + 1}. #{b}" }.join(" / ")}
        What they misplaced: #{describe_mismatches(blocks, submitted)}
        Verified result (already scored in Ruby — do not re-judge correctness or propose a different rating): #{grade(submitted, blocks.size)[:mismatches]} block(s) out of place.

        Explain WHY the misplaced blocks belong where they do — cite the actual dependency or logical reason (e.g. "this block uses a variable an earlier block declares, so it must come after it"), grounded strictly in the verified result above. Do not output a "rating" judgement of your own for this section; the rating is fixed by the verified result, not by you.
        For this section "improved_code" must be an empty string.
      PARSONS
    end

    # Normalizes and pads like .grade, so the description the reviewer gets can't contradict the score.
    def describe_mismatches(blocks, submitted_ids)
      return "cannot verify — the exercise's blocks are unavailable" if blocks.empty?

      submitted_ids = normalize_order(submitted_ids, blocks.size)
      padded = Array.new(blocks.size) { |i| submitted_ids[i] }
      descriptions = padded.each_index.filter_map { |i|
        next if padded[i] == i
        got = valid_id?(padded[i], blocks.size) ? "\"#{blocks[padded[i]]}\"" : "(nothing submitted)"
        "position #{i + 1} has #{got} (correct block there: \"#{blocks[i]}\")"
      }
      descriptions.any? ? descriptions.join("; ") : "exact match — no blocks misplaced"
    end
  end
end
