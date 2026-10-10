require_relative "comment_check/scanners"
require_relative "comment_check/route_annotation"

module CommentCheck
  MAX_PER_FILE = 5
  Offense = Struct.new(:path, :line, :message)

  module_function

  def offenses_for(path, text)
    scanner = Scanners.for(path) or return []
    comments = scanner.call(text).sort_by(&:first_line)
    lines = text.lines
    multi_line(path, comments) + unattached(path, comments, lines) + over_limit(path, comments)
  end

  def multi_line(path, comments)
    joined = comments.each_cons(2).filter_map do |previous, current|
      current.first_line if previous.own_line && current.own_line && current.first_line == previous.last_line + 1
    end
    (comments.select(&:multi_line?).map(&:first_line) + joined).uniq.map do |line|
      Offense.new(path, line, "Keep each comment to a single line.")
    end
  end

  def unattached(path, comments, lines)
    comment_lines = comments.select(&:own_line).flat_map { |comment| (comment.first_line..comment.last_line).to_a }
    comments.select(&:own_line).filter_map do |comment|
      next_line = lines[comment.last_line]
      next if next_line && !next_line.strip.empty? && !comment_lines.include?(comment.last_line + 1)

      Offense.new(path, comment.first_line, "Put the comment directly above the code it discusses.")
    end
  end

  def over_limit(path, comments)
    comments = comments.reject { |comment| comment.body.match?(ROUTE_ANNOTATION) }
    comments.drop(MAX_PER_FILE).map do |comment|
      Offense.new(path, comment.first_line, "This file has #{comments.size} comments; the limit is #{MAX_PER_FILE}.")
    end
  end
end
