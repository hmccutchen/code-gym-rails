require "psych"
require_relative "line_scan"
require_relative "c_style_scan"

module CommentCheck
  module Scanners
    PYTHON_ENCODING = /\A[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+/
    ERB_LOCALS = /\A<%#\s*locals:/
    SHELL_HEREDOC = /(?<!<)<<(?!<)(?<dash>-?)[ \t]*(?<quote>['"]?)(?<word>\w+)\k<quote>/
    DOCKERFILE_DIRECTIVE = /\A#[ \t]*(?:syntax|escape|check)[ \t]*=/i
    SHELL_SHEBANG = %r{\A#!\s*\S*?/(?:env\s+)?(?:ba)?sh\b}

    module_function

    def for(path, text = nil)
      extension = File.extname(path)
      for_file_name(File.basename(path)) || (extension.empty? ? for_shebang(text.to_s.lines.first.to_s) : for_extension(extension))
    end

    def for_file_name(name)
      case name
      when "Dockerfile" then method(:dockerfile_comments)
      when ".gitignore", ".dockerignore" then method(:ignore_file_comments)
      end
    end

    def for_shebang(line)
      method(:shell_comments) if line.match?(SHELL_SHEBANG)
    end

    def for_extension(extension)
      case extension
      when ".yml", ".yaml" then method(:yaml_comments)
      when ".py" then method(:python_comments)
      when ".css" then method(:css_comments)
      when ".js", ".mjs" then method(:js_comments)
      when ".erb" then method(:erb_comments)
      end
    end

    def yaml_comments(text)
      LineScan.line_comments(without_yaml_block_scalars(text), "#", require_space: true)
    end

    def without_yaml_block_scalars(text)
      lines = text.lines
      yaml_block_scalar_lines(text).each { |index| lines[index] = lines[index].gsub(/[^\n]/, " ") }
      lines.join
    end

    def yaml_block_scalar_lines(text)
      yaml_block_scalars(Psych.parse_stream(text)).flat_map do |scalar|
        last = scalar.end_column.zero? ? scalar.end_line - 1 : scalar.end_line
        ((scalar.start_line + 1)..last).to_a
      end
    rescue Psych::SyntaxError
      []
    end

    def yaml_block_scalars(node)
      block = node.is_a?(Psych::Nodes::Scalar) && [ Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED ].include?(node.style)
      (block ? [ node ] : []) + Array(node.children).flat_map { |child| yaml_block_scalars(child) }
    end

    def ignore_file_comments(text)
      whole_line_comments(text, /\A#/)
    end

    def dockerfile_comments(text)
      directives = text.lines.take_while { |line| line.match?(DOCKERFILE_DIRECTIVE) }.size
      whole_line_comments(without_heredoc_bodies(text), /\A[ \t]*#/).reject { |comment| comment.first_line <= directives }
    end

    def whole_line_comments(text, opener)
      offset = 0
      text.lines.filter_map do |line|
        start = offset
        offset += line.length
        Located.comment(text, start + line.index("#"), start + line.length, 0) if line.match?(opener)
      end
    end

    def python_comments(text)
      LineScan.line_comments(text, "#", require_space: false).reject { |comment| python_tooling?(comment) }
    end

    def python_tooling?(comment)
      return false unless comment.own_line && comment.first_line <= 2

      shebang?(comment) || comment.text.match?(PYTHON_ENCODING)
    end

    def shell_comments(text)
      LineScan.line_comments(without_heredoc_bodies(text), "#", require_space: true).reject { |comment| shebang?(comment) }
    end

    def without_heredoc_bodies(text)
      lines = text.lines
      index = 0
      while index < lines.length
        openers = heredoc_openers(lines[index])
        index += 1
        openers.each do |opener|
          close = (index...lines.length).find { |at| lines[at].chomp.sub(opener[:indent], "") == opener[:word] }
          break unless close

          (index..close).each { |at| lines[at] = lines[at].gsub(/[^\n]/, " ") }
          index = close + 1
        end
      end
      lines.join
    end

    def heredoc_openers(line)
      line.to_enum(:scan, SHELL_HEREDOC).map { Regexp.last_match }.select { |match| shell_code_at?(line, match.begin(0)) }
          .map { |match| { word: match[:word], indent: match[:dash].empty? ? "" : /\A\t+/ } }
    end

    def shell_code_at?(line, position)
      quote = nil
      depth = 0
      index = 0
      while index < position
        char = line[index]
        step = 1
        if quote
          quote = nil if char == quote
          step = 2 if quote == '"' && char == "\\"
        elsif char == "\\" then step = 2
        elsif char == "'" || char == '"' then quote = char
        elsif char == "#" && (index.zero? || line[index - 1].match?(/\s/)) then return false
        elsif line[index, 2] == "((" then depth += 1
        elsif line[index, 2] == "))" then depth -= 1
        end
        step = 2 if %w[(( ))].include?(line[index, 2]) && quote.nil?
        index += step
      end
      quote.nil? && depth <= 0
    end

    def shebang?(comment)
      comment.first_line == 1 && comment.text.start_with?("#!")
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
