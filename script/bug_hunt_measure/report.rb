require "json"

module BugHuntMeasure
  class Report
    class Refused < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = problems
        super("The results can't be reported:\n#{problems.map { |problem| "- #{problem}" }.join("\n")}")
      end
    end

    OUTCOMES = %w[pass fail not_runnable].freeze
    REASONS = { "pass" => %w[matched mismatched], "fail" => %w[matched mismatched],
                "not_runnable" => %w[key_unparsable syntax not_core timeout no_result] }.freeze
    LINE_KEYS = %w[harness outcome reason error].freeze
    ERROR_NAME = /\A[A-Za-z_][\w:]*\z/
    RUBY_VERSION_WANTED = "3.3.6"
    NODE_MAJOR_WANTED = "22"
    CHECK_GROUPS = { 1 => %w[bug_real], 2 => %w[returns_match], 3 => %w[looks_right], 4 => %w[fix_witness fix_looks_right] }.freeze
    THRESHOLD_CHECKS = [ 1, 3, 4 ].freeze
    THRESHOLD = 2
    SAMPLE_PER_LANGUAGE = 2
    WIDTHS = [ 45, 60 ].freeze

    def initialize(harness_dir, results_paths, out_dir, seed: Random.new_seed)
      @manifest = JSON.parse(File.read(File.join(harness_dir, "manifest.json")))
      @dir      = harness_dir
      @results  = results_paths.map { |path| [ path, File.readlines(path, chomp: true).reject(&:empty?) ] }
      @out_dir  = BugHuntMeasure.outside_repository!(out_dir)
      @seed     = seed
      raise ArgumentError, "#{@out_dir} already exists" if File.exist?(@out_dir)
    end

    def call
      runs, lines = read_results
      by_harness  = lines.index_by { |line| line["harness"] }
      drafts      = @manifest["drafts"].map { |draft| draft_result(draft, by_harness) }

      FileUtils.mkdir_p(@out_dir)
      File.write(File.join(@out_dir, "failures.md"), sheet(drafts))
      counts = counts_text(runs, drafts, lines)
      File.write(File.join(@out_dir, "counts.txt"), counts)
      counts
    end

    private

    def read_results
      problems = []
      runs  = @results.map { |path, file_lines| run_line(path, file_lines.first, problems) }
      lines = @results.flat_map { |path, file_lines| file_lines.drop(1).filter_map { |text| result_line(path, text, problems) } }
      check_coverage(runs, lines, problems)
      raise Refused, problems if problems.any?

      [ runs, lines ]
    end

    def run_line(path, text, problems)
      run = parse(text)
      unless run.is_a?(Hash) && run["build"].is_a?(String) && run["runtime"].is_a?(Hash)
        problems << "#{path} has no run line first"
        return { "path" => path, "runtime" => {} }
      end

      problems << "#{path} is from build #{run["build"]}, not #{@manifest["build_id"]}" if run["build"] != @manifest["build_id"]
      ruby, node = run["runtime"].values_at("ruby", "node")
      problems << "#{path} ran Ruby #{ruby}, not #{RUBY_VERSION_WANTED}" if ruby && ruby != RUBY_VERSION_WANTED
      problems << "#{path} ran Node #{node}, not #{NODE_MAJOR_WANTED}.x" if node && node.split(".").first != NODE_MAJOR_WANTED
      run.merge("path" => path)
    end

    def result_line(path, text, problems)
      line = parse(text)
      return line if valid_line?(line)

      problems << "#{path} has a line outside the results format: #{text.truncate(120)}"
      nil
    end

    def valid_line?(line)
      line.is_a?(Hash) && (line.keys - LINE_KEYS).empty? && line["harness"].is_a?(String) &&
        OUTCOMES.include?(line["outcome"]) && REASONS.fetch(line["outcome"], []).include?(line["reason"]) &&
        (line["error"].nil? || line["error"].to_s.match?(ERROR_NAME))
    end

    def check_coverage(runs, lines, problems)
      expected = @manifest["harnesses"].map { |harness| harness["harness"] }
      counted  = lines.map { |line| line["harness"] }.tally
      (expected - counted.keys).each { |id| problems << "no result for #{id}" }
      counted.select { |_id, count| count > 1 }.each_key { |id| problems << "more than one result for #{id}" }
      (counted.keys - expected).each { |id| problems << "a result for #{id}, which this build has no harness for" }
      ran = runs.flat_map { |run| run["runtime"].keys }
      (@manifest["harnesses"].map { |harness| harness["runtime"] }.uniq - ran).each do |runtime|
        problems << "no results file ran #{runtime}"
      end
    end

    def parse(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    def draft_result(draft, by_harness)
      harnesses = @manifest["harnesses"].select { |harness| harness["draft"] == draft["draft"] }
      lines     = harnesses.to_h { |harness| [ harness["check"], by_harness.fetch(harness["harness"]) ] }
      checks    = CHECK_GROUPS.transform_values do |names|
        present = lines.values_at(*names).compact
        next "absent" if present.empty?

        present.all? { |line| line["outcome"] == "pass" } ? "pass" : "fail"
      end
      core = lines.values.any? { |line| line["reason"] == "not_core" } ? "fail" : "pass"
      draft.merge("checks" => checks.merge(5 => core), "lines" => lines, "harnesses" => harnesses)
    end

    def failed?(draft) = draft["checks"].values.include?("fail")

    def counts_text(runs, drafts, lines)
      threshold = drafts.count { |draft| THRESHOLD_CHECKS.any? { |check| draft["checks"][check] == "fail" } }
      [
        *runs.map { |run| "#{File.basename(run["path"])}: network #{run["network"]}, #{run["runtime"].map { |k, v| "#{k} #{v}" }.join(', ')}" },
        "drafts: #{drafts.size} · harnesses: #{lines.size}",
        *CHECK_GROUPS.keys.map { |check| check_line(check, drafts) }, check_line(5, drafts),
        "harness outcomes: #{lines.map { |line| [ line["outcome"], line["reason"] ].join('/') }.tally.sort.map { |k, v| "#{k} #{v}" }.join(' · ')}",
        "drafts failing check 1, 3 or 4: #{threshold} of #{drafts.size} " \
          "(#{threshold > THRESHOLD ? 'more than' : 'at most'} #{THRESHOLD}: #{threshold > THRESHOLD ? 'sandbox question' : 'ship as specified'})",
        *drafts.select { |draft| failed?(draft) }.map { |draft| "#{draft["registry_id"]}: failed #{failed_checks(draft).join(', ')}" },
        *WIDTHS.map { |width| "drafts with a line past #{width}: #{drafts.count { |draft| draft["longest_line"].to_i > width }}" },
        "sample seed: #{@seed}"
      ].join("\n") + "\n"
    end

    def check_line(check, drafts)
      outcomes = drafts.map { |draft| draft["checks"][check] }.tally
      "check #{check}: pass #{outcomes.fetch('pass', 0)} · fail #{outcomes.fetch('fail', 0)} · absent #{outcomes.fetch('absent', 0)}"
    end

    def failed_checks(draft) = draft["checks"].select { |_check, outcome| outcome == "fail" }.keys.map { |check| "check #{check}" }

    def sheet(drafts)
      failures = drafts.select { |draft| failed?(draft) }
      random   = Random.new(@seed)
      sample   = drafts.reject { |draft| failed?(draft) }.group_by { |draft| draft["language"] }
                       .flat_map { |_language, passing| passing.sample(SAMPLE_PER_LANGUAGE, random: random) }
      [ "# bug_hunt measurement", "", "## Failures (#{failures.size})", *failures.map { |draft| draft_block(draft) },
        "## Passing sample (seed #{@seed})", *sample.map { |draft| draft_block(draft) } ].join("\n")
    end

    def draft_block(draft)
      key = draft["answer_key"]
      [
        "### #{draft["draft"]} · #{draft["registry_id"]} · #{draft["rung"]}", "",
        "Checks: #{draft["checks"].map { |check, outcome| "#{check} #{outcome}" }.join(' · ')}", "",
        "Purpose: #{draft["purpose"]}", "", fenced(draft["snippet"]),
        "Issue: #{key["issue"]}", "", "Why it matters: #{key["why_it_matters"]}", "", "Fix: #{key["fix"]}", "",
        "Fixed snippet:", fenced(key["fixed_snippet"].to_s),
        *draft["harnesses"].map { |harness| harness_block(harness, draft["lines"].fetch(harness["check"])) }
      ].join("\n")
    end

    def harness_block(harness, line)
      files = Dir.glob(File.join(@dir, "#{harness["harness"]}.{subject,expected}.*")).sort
      [ "#### #{harness["harness"]}", "", "Result: `#{line.to_json}`", "",
        *files.flat_map { |path| [ "#{File.basename(path)}:", fenced(File.read(path)) ] } ].join("\n")
    end

    def fenced(text) = "```\n#{text.chomp}\n```\n"
  end
end
