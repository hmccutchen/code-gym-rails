require_relative "comment"
require_relative "line_scan"

module CommentCheck
  module Scanners
    TOOLING = /\A\s*(#!|# -\*-|<%#\s*locals:)/

    module_function

    def for(path)
      case File.extname(path)
      when ".yml", ".yaml", ".py" then method(:hash_comments)
      when ".css" then method(:css_comments)
      when ".js", ".mjs" then method(:js_comments)
      when ".erb" then method(:erb_comments)
      end
    end

    def hash_comments(text)
      lines = text.lines
      LineScan.line_comments(lines, "#").reject { |comment| lines[comment.first_line - 1].match?(TOOLING) }
    end

    def css_comments(text, offset: 0)
      LineScan.delimited_comments(text, "/*", "*/", offset: offset)
    end

    def js_comments(text, offset: 0)
      css_comments(text, offset: offset) + LineScan.line_comments(text.lines, "//", offset: offset)
    end

    def erb_comments(text)
      erb = LineScan.delimited_comments(text, "<%#", "%>").reject { |comment| text.lines[comment.first_line - 1].match?(TOOLING) }
      erb + LineScan.delimited_comments(text, "<!--", "-->") + embedded(text, "script", :js_comments) + embedded(text, "style", :css_comments)
    end

    def embedded(text, tag, scanner)
      text.to_enum(:scan, %r{<#{tag}\b[^>]*>(.*?)</#{tag}>}m).flat_map do
        body_start = Regexp.last_match.begin(1)
        send(scanner, Regexp.last_match[1], offset: text[0...body_start].count("\n"))
      end
    end
  end
end
