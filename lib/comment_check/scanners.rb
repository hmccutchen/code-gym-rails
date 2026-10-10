require_relative "line_scan"
require_relative "c_style_scan"

module CommentCheck
  module Scanners
    PYTHON_ENCODING = /\A[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+/
    ERB_LOCALS = /\A<%#\s*locals:/

    module_function

    def for(path)
      case File.extname(path)
      when ".yml", ".yaml" then method(:yaml_comments)
      when ".py" then method(:python_comments)
      when ".css" then method(:css_comments)
      when ".js", ".mjs" then method(:js_comments)
      when ".erb" then method(:erb_comments)
      end
    end

    def yaml_comments(text)
      LineScan.line_comments(text, "#", require_space: true)
    end

    def python_comments(text)
      LineScan.line_comments(text, "#", require_space: false).reject { |comment| python_tooling?(comment) }
    end

    def python_tooling?(comment)
      return false unless comment.own_line && comment.first_line <= 2

      comment.text.start_with?("#!") && comment.first_line == 1 || comment.text.match?(PYTHON_ENCODING)
    end

    def css_comments(text, offset: 0)
      CStyleScan.comments(text, line_comments: false, offset: offset)
    end

    def js_comments(text, offset: 0)
      CStyleScan.comments(text, line_comments: true, offset: offset)
    end

    def erb_comments(text)
      erb = LineScan.delimited_comments(text, "<%#", "%>").reject { |comment| comment.text.match?(ERB_LOCALS) }
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
