# Read-only, and prints totals only, never which position any one exercise or user got.
class AnswerPositionBalance
  KIND = ExerciseSection::DesignComparison

  def initialize(out: $stdout)
    @out = out
  end

  # Shares are of the usable positions alone, so they always sum to 100.
  def report
    counts = positions.tally
    total  = counts.slice(*KIND::PIECES).values.sum
    @out.puts "design comparisons with a usable position: #{total}"
    KIND::PIECES.each do |piece|
      share = total.zero? ? 0 : (100.0 * counts.fetch(piece, 0) / total).round(1)
      @out.puts "better piece shown as #{piece.upcase}: #{counts.fetch(piece, 0)} (#{share}%)"
    end
    @out.puts "no usable position: #{counts.except(*KIND::PIECES).values.sum}"
  end

  private

  def positions
    DailyExercise.where("problem_set ? :key", key: KIND.key)
                 .pluck(Arel.sql("problem_set -> #{DailyExercise.connection.quote(KIND.key)} -> " \
                                 "#{DailyExercise.connection.quote(KIND::ANSWER_KEY_FIELD)} ->> 'better'"))
  end
end
