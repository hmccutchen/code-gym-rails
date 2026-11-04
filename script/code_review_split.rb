# Design notes: docs/code-notes/script/code_review_split.md
require_relative "review_baseline_export"

class CodeReviewSplit
  KIND = ExerciseSection::CodeReview
  SHAPES = %w[single multi bug_hunt].freeze
  RATINGS = ConceptMastery::AI_RATING_RANK.keys.freeze
  UNRATED = "unrated".freeze
  MULTI_KEY_LINE = /\[planted_key\] answer_key=(\w+) kind=code_review .*\bcode_review_files=multi\b/

  def initialize(out: $stdout, log_lines: nil)
    @out = out
    @log_lines = log_lines
  end

  def report
    counts = ReviewBaselineExport.read_only { results.tally }
    @out.puts "reviewed code_review results: #{counts.values.sum}"
    counts.keys.map { |shape, rung, _| [ shape, rung ] }.uniq.sort_by { |shape, rung| [ SHAPES.index(shape), rung_order(rung) ] }
          .each { |shape, rung| @out.puts "  #{shape} #{rung}: #{line_for(counts, shape, rung)}" }
    @out.puts "multi-file code_review key notes: #{key_note_line}"
  end

  private

  def results
    DailyResponse.submitted.reviewed.includes(:daily_exercise).find_each.filter_map do |response|
      section = response.daily_exercise.problem_set[KIND.key]
      next unless section.is_a?(Hash) && response.ai_review.is_a?(Hash) && response.ai_review.key?(KIND.key)

      [ shape(section), section["pitched_at"].presence || "unrecorded", response.ai_rating_for(KIND.key) || UNRATED ]
    end
  end

  def shape(section)
    return "bug_hunt" if KIND.bug_hunt?(section)

    KIND.files(section).any? ? "multi" : "single"
  end

  def rung_order(rung) = KindDifficulty::LEVELS.index(rung) || KindDifficulty::LEVELS.size

  def line_for(counts, shape, rung)
    ratings = counts.select { |(each_shape, each_rung, _), _| each_shape == shape && each_rung == rung }
                    .transform_keys(&:last)
    "#{ratings.values.sum} (#{(RATINGS + [ UNRATED ]).map { |rating| "#{rating} #{ratings.fetch(rating, 0)}" }.join(', ')})"
  end

  def key_note_line
    return "no log given" if @log_lines.nil?

    outcomes = @log_lines.filter_map { |line| line[MULTI_KEY_LINE, 1] }.tally.sort_by { |outcome, count| [ -count, outcome ] }
    "#{outcomes.sum(&:last)} (#{outcomes.map { |outcome, count| "#{outcome} #{count}" }.join(', ')})"
  end
end
