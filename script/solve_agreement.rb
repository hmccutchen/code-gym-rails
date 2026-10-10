# Prints counts only, never a solve or a key, so its output can be pasted anywhere.
class SolveAgreement
  GROUPINGS = { "rung" => :rung, "concept" => :concept }.freeze

  def initialize(rows, out:)
    @rows = rows
    @out  = out
  end

  def print(heading)
    return if @rows.empty?

    @out.puts "blind solve, #{heading}: #{line(@rows)}"
    GROUPINGS.each do |label, field|
      @rows.group_by { |row| row[field] }.sort_by { |value, _| value.to_s }.each do |value, rows|
        @out.puts "  #{label} #{value}: #{line(rows)}"
      end
    end
  end

  private

  def line(rows)
    valid   = rows.reject { |row| row[:matched].nil? }
    matches = valid.count { |row| row[:matched] }

    "valid-solve agreement #{matches}/#{valid.size} · matches of attempted #{matches}/#{rows.size} · " \
      "invalid #{count(rows, :invalid)} · errors #{count(rows, :error)} · " \
      "rejections #{count(rows, :reject)} (false #{rows.count { |row| row[:false_reject] }})"
  end

  def count(rows, status)
    rows.count { |row| row[:status] == status }
  end
end
