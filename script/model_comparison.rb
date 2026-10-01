# Runs one stored input through two Claude models and prints both results
# side by side, for a person to read and judge. Nothing in app/ loads this.
#
# Calls are billed to the key passed in, never the stored user's own key, and
# usage is kept in memory rather than written as ApiUsage rows, since those
# rows would charge a teammate's history for a comparison they never ran.
class ModelComparison
  CANDIDATES = {
    "generate"  => [ { model: "claude-sonnet-5-5", effort: "high" }, { model: "claude-opus-5-5", effort: "medium" } ],
    "review"    => [ { model: "claude-sonnet-5-5", effort: "high" }, { model: "claude-opus-5-5" } ],
    "duck"      => [ { model: "claude-sonnet-5-5", effort: "high" }, { model: "claude-haiku-4-5" } ],
    "translate" => [ { model: "claude-sonnet-5-5", effort: "high" }, { model: "claude-haiku-4-5" } ],
    "judge"     => [ { model: "claude-sonnet-5-5", effort: "high" }, { model: "claude-haiku-4-5" } ],
    "review_prose" => [ { model: "claude-sonnet-5-5", effort: "high" }, { model: "claude-haiku-4-5" } ],
    # The route production grades with, so the run measures the rubric as
    # deployed rather than a candidate.
    "review_calibration" => [ ClaudeService::MODEL_FOR_PURPOSE.fetch("review_response", ClaudeService::DEFAULT_ROUTE) ]
  }.freeze

  REVIEW_FIELDS = %w[rating missed next_step].freeze
  VERDICT_FIELDS = %w[status issues principle evidence reason].freeze

  FIXTURE_DIR = Rails.root.join("spec/fixtures/judge")
  REVIEW_PROSE_FIXTURE_DIR = Rails.root.join("spec/fixtures/review_judge")
  REVIEW_CALIBRATION_FIXTURE_DIR = Rails.root.join("spec/fixtures/review_calibration")

  # What AiService::RATING_RUBRIC should give each answer a calibration
  # fixture carries, in descending order of quality.
  CALIBRATION_EXPECTED = {
    "complete" => %w[solid strong],
    "partial"  => %w[developing],
    "miss"     => %w[beginner]
  }.freeze

  # List prices as of writing, per million tokens; read nowhere in app/ — this
  # is what #judge_fixtures prices a candidate's run against, for a person
  # comparing them, never anything billed.
  LIST_PRICE_PER_MILLION = {
    "claude-sonnet-5-5" => { input: 2.0, output: 10.0 },
    "claude-haiku-4-5"  => { input: 1.0, output: 5.0 }
  }.freeze

  Run = Data.define(:route, :output, :seconds, :tokens_in, :tokens_out)

  # One judge call's outcome for one model and one input: :keep or :edit with
  # its verdict, :invalid when the reply was not a usable verdict, :error when
  # the provider call failed. Kept whole so a model's summary is computed from
  # every input, failures and their waiting time included.
  ProseResult = Data.define(:label, :outcome, :verdict, :error, :ms, :tokens_in, :tokens_out, :expected)

  def initialize(api_key:, out: $stdout)
    @api_key = api_key
    @out     = out
  end

  def generate(user_id)
    user     = User.find(user_id)
    language = user.language_for_today
    plan     = DailyPlan.for(user, language: language)

    compare("generate", heading: "user #{user.id}, #{language}") do |service|
      problem_set = with_fixed_plan(plan) { service.generate_exercise(user, language: language) }
      # Printed output is read in a terminal and pasted around, which is the
      # storage AiService#without_answer_key exists to keep the ambiguity-hunt
      # key out of.
      service.send(:without_answer_key, problem_set)
    end
  end

  def review(daily_response_id)
    response = DailyResponse.find(daily_response_id)
    exercise = response.daily_exercise

    response.section_keys.select { |section| response.answered?(section) }.each do |section|
      compare("review", heading: review_heading(response, section)) do |service|
        review_section(service, response, exercise, section)
      end
    end
  end

  def duck(daily_exercise_id, section:, message: AiService::DUCK_EXPLAIN_REQUEST)
    exercise = DailyExercise.find(daily_exercise_id)

    compare("duck", heading: section) do |service|
      service.duck_response(exercise.user, exercise, section: section, message: message)
    end
  end

  def translate(daily_response_id, section: "pseudocode_to_code")
    response   = DailyResponse.find(daily_response_id)
    pseudocode = response.answers[section].presence or raise ArgumentError, "Response #{response.id} has no #{section} answer"

    compare("translate", heading: section) do |service|
      service.translate_pseudocode(response.user, response.daily_exercise, section: section, pseudocode: pseudocode)
    end
  end

  # Drafts one problem set through the pinned generation route (so both judge
  # candidates score the same sections), then sends every drafted section
  # through each candidate's own judge_section, one section at a time. A
  # section's own verdict, or its error class and message, stands in its
  # place the way timed_run already does for a whole run — one bad section
  # never loses the rest of the candidate's output.
  def judge(user_id)
    user       = User.find(user_id)
    language   = user.language_for_today
    plan       = DailyPlan.for(user, language: language)
    difficulty = KindDifficulty.for(user)

    draft = with_fixed_plan(plan) do
      pinned_service(CANDIDATES.fetch("generate").first, []).send(:draft_exercise, user, language: language, blocking: true)
    end

    compare("judge", heading: "user #{user.id}, #{language}") do |service|
      judge_draft(service, user, draft, difficulty)
    end
  end

  # Runs every fixture under spec/fixtures/judge through each judge candidate
  # and prints a detection table per model: whether the output parsed, whether
  # a broken fixture was caught under its own principle, whether a sound
  # fixture was wrongly rejected, and cost from the accumulated tokens at the
  # model's list price. No user_id: the fixtures carry their own rung/lock,
  # and the fixture user is never persisted.
  def judge_fixtures
    fixtures = Dir[FIXTURE_DIR.join("*.json")].sort.map { |path| load_fixture(path) }
    user     = User.new(skill_level: "solid")

    CANDIDATES.fetch("judge").each { |route| print_fixture_table(route, fixtures, user) }
  end

  # Runs the prose judge over a user's stored reviews, newest first. A review
  # the live judge already edited is measured from the grader's original, kept
  # under graded_prose.
  def review_prose(user_id, limit: 5)
    raise ArgumentError, "limit must be a positive integer" unless limit.is_a?(Integer) && limit.positive?

    user   = User.find(user_id)
    inputs = stored_review_inputs(user, limit)
    CANDIDATES.fetch("review_prose").each do |route|
      run_prose_judge("review_prose: user #{user.id} · #{route[:model]}", route, inputs, user)
    end
  end

  def review_prose_fixtures
    user   = User.new(skill_level: "solid")
    inputs = Dir[REVIEW_PROSE_FIXTURE_DIR.join("*.json")].sort.map { |path| fixture_input(load_fixture(path)) }
    CANDIDATES.fetch("review_prose").each do |route|
      run_prose_judge("review_prose_fixtures: #{route[:model]}", route, inputs, user)
    end
  end

# Grades each calibration fixture's complete, partial and missed answers
# through the real review prompt. A fixture passes when the three ratings
# fall in rank order; the expected ratings are printed beside the actual
# ones for a person to read.
def review_calibration
  user     = User.new(skill_level: "developing")
  fixtures = Dir[REVIEW_CALIBRATION_FIXTURE_DIR.join("*.json")].sort.map { |path| load_fixture(path) }

  CANDIDATES.fetch("review_calibration").each do |route|
    @out.puts "=== review_calibration: #{route[:model]} ==="
    rows = fixtures.map { |fixture| calibration_row(route, user, fixture) }
    print_calibration_summary(route, rows)
  end
end

  private

  def load_fixture(path)
    JSON.parse(File.read(path)).merge("name" => File.basename(path, ".json"))
  end

  def judge_draft(service, user, draft, difficulty)
    draft.kinds.filter_map do |kind|
      section = draft.problem_set[kind.key]
      [ kind.key, judge_drafted_section(service, user, kind, section, difficulty) ] if section
    end.to_h
  end

  def judge_drafted_section(service, user, kind, section, difficulty)
    verdict = service.judge_section(
      user, kind, section,
      rung: difficulty.rung_for(kind, skill_level: user.skill_level), locked: difficulty.locked?(kind)
    )
    VERDICT_FIELDS.index_with { |field| verdict.public_send(field) }
  rescue JudgeVerdict::Invalid, AiService::Error => e
    "#{e.class}: #{e.message}"
  end

  def print_fixture_table(route, fixtures, user)
    usage   = []
    service = pinned_service(route, usage)
    rows    = fixtures.map { |fixture| fixture_row(service, user, fixture) }

    @out.puts "=== judge_fixtures: #{route[:model]} ==="
    rows.each { |row| print_fixture_row(row) }
    print_fixture_totals(route, rows, usage)
    @out.puts
  end

  def print_fixture_row(row)
    @out.puts "#{row[:name]}: expected=#{row[:expected]} got=#{row[:status] || row[:classification]} " \
              "classification=#{row[:classification]} principle=#{row[:principle]} #{row[:ms]}ms" \
              "#{fixture_row_detail(row)}"
  end

  def fixture_row_detail(row)
    return " (#{row[:error]})" if row[:error]
    return "" if row[:issues].blank?

    " issues=" + row[:issues].map { |issue| "#{issue[:type]}: #{issue[:evidence].inspect}" }.join("; ")
  end

  def print_fixture_totals(route, rows, usage)
    broken        = rows.select { |row| row[:expected] == "reject" }
    sound         = rows.select { |row| row[:expected] == "keep_or_edit" }
    valid         = rows.reject { |row| %i[invalid error].include?(row[:classification]) }
    detected      = broken.count { |row| row[:classification] == :detected }
    false_rejects = sound.count { |row| row[:classification] == :false_reject }
    tokens_in     = usage.sum { |row| row[:tokens_in] }
    tokens_out    = usage.sum { |row| row[:tokens_out] }

    @out.puts "valid: #{valid.size}/#{rows.size} · detected: #{detected}/#{broken.size} · " \
              "false rejections: #{false_rejects}/#{sound.size} · " \
              "#{rows.sum { |row| row[:ms] }}ms · #{tokens_in} in / #{tokens_out} out · " \
              "$#{format('%.4f', fixture_cost(route[:model], tokens_in, tokens_out))}"
    print_detection_per_principle(broken)
  end

  def print_detection_per_principle(broken)
    broken.map { |row| row[:expected_principle] }.uniq.sort.each do |principle|
      total    = broken.count { |row| row[:expected_principle] == principle }
      detected = broken.count { |row| row[:expected_principle] == principle && row[:classification] == :detected }
      @out.puts "#{principle}: #{detected}/#{total}"
    end
  end

  def fixture_cost(model, tokens_in, tokens_out)
    price = LIST_PRICE_PER_MILLION.fetch(model)
    (tokens_in * price[:input] + tokens_out * price[:output]) / 1_000_000.0
  end

  # A provider failure is an error row, not invalid output, so one fixture's
  # timeout neither ends the run nor counts against the model's valid rate
  # as if it had answered badly.
  def fixture_row(service, user, fixture)
    kind    = ExerciseSection.for(fixture["kind"])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result  = begin
      fixture_result(fixture, service.judge_section(user, kind, fixture["section"],
                                                    rung: fixture["rung"], locked: fixture["locked"]))
    rescue JudgeVerdict::Invalid => e
      fixture_failure(fixture, :invalid, e)
    rescue AiService::Error => e
      fixture_failure(fixture, :error, e)
    end

    result.merge(ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round)
  end

  def fixture_result(fixture, verdict)
    fixture_identity(fixture).merge(status: verdict.status, principle: verdict.principle, issues: verdict.issues,
                                    classification: classify_fixture(fixture, verdict))
  end

  def fixture_failure(fixture, classification, error)
    fixture_identity(fixture).merge(classification: classification, error: "#{error.class}: #{error.message}")
  end

  def fixture_identity(fixture)
    { name: fixture["name"], expected: fixture["expected"], expected_principle: fixture["principle"] }
  end

  # detected/wrong_principle/missed for a fixture whose section is meant to be
  # caught; ok/false_reject for one that's meant to survive.
  def classify_fixture(fixture, verdict)
    if fixture["expected"] == "reject"
      return :missed unless verdict.reject?

      verdict.principle == fixture["principle"] ? :detected : :wrong_principle
    else
      verdict.reject? ? :false_reject : :ok
    end
  end

  def compare(mode, heading:)
    runs = CANDIDATES.fetch(mode).map { |route| timed_run(route) { |service| yield service } }
    print_runs(mode, heading, runs)
    runs
  end

  def timed_run(route)
    usage   = []
    service = pinned_service(route, usage)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output  = begin
      yield service
    rescue AiService::Error, JSON::ParserError => e
      "#{e.class}: #{e.message}"
    end

    Run.new(route: route, output: output, seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
            tokens_in: usage.sum { |row| row[:tokens_in] }, tokens_out: usage.sum { |row| row[:tokens_out] })
  end

  # A subclass per route rather than an instance setting, because the review
  # fan-out builds fresh instances with `self.class.new`.
  def pinned_service(route, usage)
    lock = Mutex.new

    Class.new(ClaudeService) do
      # A grading comparison measures the grader alone, whatever the
      # deployment's switch says; the review_prose modes call the judge
      # directly instead.
      def self.judges_review_prose? = false

      define_method(:route_for) { |_purpose| route }
      define_method(:log_usage) do |_user, result, purpose:|
        lock.synchronize { usage << { tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i } }
      end
      define_method(:record_suggested_concept) { |_suggestion| }
      private :route_for, :log_usage, :record_suggested_concept
    end.new(@api_key)
  end

  def stored_review_inputs(user, limit)
    responses = DailyResponse.where(user: user).where.not(ai_review: nil)
                             .includes(:daily_exercise).order(date: :desc).limit(limit)
    responses.flat_map do |response|
      coach = coach_for(response.daily_exercise.language)
      response.ai_review.filter_map do |section, review|
        next unless review.is_a?(Hash) && ExerciseSection.keys.include?(section)

        { label: "#{response.date} #{section}", kind: ExerciseSection.for(section), coach: coach,
          review: review.merge(review.fetch(ReviewProseVerdict::ORIGINAL_KEY, {})) }
      end
    end
  end

  def fixture_input(fixture)
    { label: fixture["name"], kind: ExerciseSection.for(fixture["kind"]), coach: fixture["coach"],
      review: fixture["review"], expected: fixture["expected"], must_survive: fixture["must_survive"] }
  end

  def coach_for(language) = AiService::LANGUAGE_CONFIG.fetch(language)[:coach]

  def run_prose_judge(heading, route, inputs, user)
    usage   = []
    service = pinned_service(route, usage)
    @out.puts "=== #{heading} ==="
    results = inputs.map do |input|
      judge_prose_input(service, usage, user, input).tap { |result| print_prose_result(result, input) }
    end
    print_prose_summary(route, results)
    @out.puts
    results
  end

  # Elapsed time and tokens are measured on failure too, so a model that keeps
  # timing out cannot look fast.
  def judge_prose_input(service, usage, user, input)
    seen    = usage.size
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome, verdict, error = prose_outcome { service.judge_review_prose(user, input[:kind], input[:review], coach: input[:coach]) }
    calls = usage.drop(seen)
    ProseResult.new(label: input[:label], outcome: outcome, verdict: verdict, error: error, expected: input[:expected],
                    ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round,
                    tokens_in: calls.sum { |row| row[:tokens_in] }, tokens_out: calls.sum { |row| row[:tokens_out] })
  end

  def prose_outcome
    verdict = yield
    [ verdict.status, verdict, nil ]
  rescue ReviewProseVerdict::Invalid, AiService::InvalidResponseError => e
    [ :invalid, nil, "#{e.class}: #{e.message}" ]
  rescue AiService::Error => e
    [ :error, nil, "#{e.class}: #{e.message}" ]
  end

  # Review text is printed here by design: it is read by a person in a
  # terminal, not stored in application logs.
  def print_prose_result(result, input)
    @out.puts "#{result.label}: #{result.outcome}#{" (expected #{result.expected})" if result.expected} " \
              "#{result.ms}ms · #{result.tokens_out} out"
    @out.puts "  must survive: #{input[:must_survive].join(' | ')}" if input[:must_survive].present?
    lines = result.verdict ? rewrite_lines(result.verdict, ReviewProseVerdict.project(input[:review])) : [ result.error ]
    lines.each { |line| @out.puts "  #{line}" }
  end

  # Each rewritten entry printed beside the originals it cites, so a reader can
  # check the claim survived.
  def rewrite_lines(verdict, projection)
    return [ "keep" ] unless verdict.edit?

    issues = verdict.issues.map { |issue| "#{issue[:type]}: #{issue[:evidence].inspect}" }.join("; ")
    [ "edit · issues: #{issues}" ] + verdict.fields.flat_map { |field, value| rewritten_field_lines(field, value, projection[field]) }
  end

  def rewritten_field_lines(field, value, original)
    return [ "#{field}:", "  was: #{original}", "  now: #{value}" ] unless value.is_a?(Array)

    [ "#{field}:" ] + value.flat_map do |entry|
      [ "  #{entry[:from].inspect} now: #{entry[:text]}" ] + entry[:from].map { |i| "      was[#{i}]: #{original[i]}" }
    end
  end

  def print_prose_summary(route, results)
    valid = results.select { |result| %i[keep edit].include?(result.outcome) }
    edits = valid.select { |result| result.outcome == :edit }
    tokens_in  = results.sum(&:tokens_in)
    tokens_out = results.sum(&:tokens_out)
    @out.puts "edits: #{edits.size}/#{valid.size} (#{issue_rates(edits, valid.size)}) · " \
              "merges: #{edits.sum { |result| result.verdict.merges.values.sum(&:size) }} · " \
              "invalid: #{results.count { |result| result.outcome == :invalid }}/#{results.size} · " \
              "provider errors: #{results.count { |result| result.outcome == :error }}/#{results.size} · " \
              "#{results.sum(&:ms)}ms · #{tokens_in} in / #{tokens_out} out · " \
              "$#{format('%.4f', fixture_cost(route[:model], tokens_in, tokens_out))}"
    print_prose_extremes(results)
    expected = results.select(&:expected)
    @out.puts "matched expected status: #{expected.count { |result| result.outcome.to_s == result.expected }}/#{expected.size}" if expected.any?
  end

  # The activation gate checks single replies against the cap and the one
  # attempt's timeout, which totals hide.
  def print_prose_extremes(results)
    return if results.empty?

    largest = results.max_by(&:tokens_out)
    slowest = results.max_by(&:ms)
    @out.puts "largest reply: #{largest.tokens_out} out (#{largest.label}) of the #{AiService::REVIEW_JUDGE_MAX_TOKENS} cap · " \
              "slowest: #{slowest.ms}ms (#{slowest.label}) of the #{AiService::REVIEW_JUDGE_READ_TIMEOUT * 1_000}ms timeout"
  end

  def issue_rates(edits, valid_count)
    ReviewProseVerdict::ISSUE_TYPES.map do |type|
      "#{type} #{edits.count { |result| result.verdict.issues.any? { |issue| issue[:type] == type } }}/#{valid_count}"
    end.join(", ")
  end

def calibration_row(route, user, fixture)
  graded = CALIBRATION_EXPECTED.keys.to_h { |quality| [ quality, grade_calibration_answer(route, user, fixture, quality) ] }
  ranks  = graded.values.map { |run| ConceptMastery::AI_RATING_RANK[run.output["rating"]] if run.output.is_a?(Hash) }
  ordered = ranks.all? && ranks.each_cons(2).all? { |better, worse| better > worse }

  @out.puts "--- #{fixture['name']} (#{fixture['kind']}, #{fixture.dig('section', 'pitched_at')}) · #{ordered ? 'in order' : 'OUT OF ORDER'} ---"
  graded.each { |quality, run| @out.puts calibration_line(quality, run) }
  { ordered: ordered, graded: graded }
end

def grade_calibration_answer(route, user, fixture, quality)
  kind     = fixture["kind"]
  exercise = DailyExercise.new(user: user, language: fixture["language"], problem_set: { kind => fixture["section"] })
  response = DailyResponse.new(user: user, daily_exercise: exercise, answers: { kind => fixture.dig("answers", quality) },
                               section_ratings: { kind => "right_level" })

  timed_run(route) do |service|
    context = service.send(:build_review_day_context, coach_for(fixture["language"]), exercise, response)
    _, result = service.send(:grade_section, user, exercise, response, kind, context)
    result[:ok] ? result[:review] : "#{result[:error_code]}: #{result[:message]}"
  end
end

def calibration_line(quality, run)
  return "  #{quality.ljust(8)} error: #{run.output}" unless run.output.is_a?(Hash)

  review   = run.output
  expected = CALIBRATION_EXPECTED.fetch(quality)
  check    = RubricCheck.new(review)
  "  #{quality.ljust(8)} #{review['rating'].to_s.ljust(10)} expected #{expected.join('/').ljust(13)}" \
    "#{expected.include?(review['rating']) ? 'match' : 'MISMATCH'} · essential #{check.essential_gaps&.size || '?'}" \
    " of #{check.missed_count} missed · rubric #{check.agrees?.nil? ? 'unchecked' : (check.agrees? ? 'agrees' : 'DISAGREES')}" \
    " · #{format('%.1f', run.seconds)}s"
end

def print_calibration_summary(route, rows)
  runs       = rows.flat_map { |row| row[:graded].to_a }
  graded     = runs.select { |_quality, run| run.output.is_a?(Hash) }
  matched    = graded.count { |quality, run| CALIBRATION_EXPECTED.fetch(quality).include?(run.output["rating"]) }
  agreeing   = graded.count { |_quality, run| RubricCheck.new(run.output).agrees? }
  tokens_in  = runs.sum { |_quality, run| run.tokens_in }
  tokens_out = runs.sum { |_quality, run| run.tokens_out }

  @out.puts "in order: #{rows.count { |row| row[:ordered] }}/#{rows.size} · matched expected: #{matched}/#{runs.size} · " \
            "rating agrees with essential gaps: #{agreeing}/#{graded.size} · " \
            "complete answers rated solid or better: #{graded.count { |quality, run| quality == 'complete' && %w[solid strong].include?(run.output['rating']) }}/#{rows.size} · " \
            "#{tokens_in} in / #{tokens_out} out · $#{format('%.4f', fixture_cost(route[:model], tokens_in, tokens_out))}"
  @out.puts
end

  def review_section(service, response, exercise, section)
    coach   = service.send(:config_for, exercise.language)[:coach]
    context = service.send(:build_review_day_context, coach, exercise, response)
    _, result = service.send(:grade_section, response.user, exercise, response, section, context)

    result[:ok] ? result[:review].slice(*REVIEW_FIELDS) : "#{result[:error_code]}: #{result[:message]}"
  end

  # A real review translates pseudocode before grading it and saves the result.
  # This one grades without writing anything, so an untranslated plan is
  # graded as written.
  def review_heading(response, section)
    return section unless ExerciseSection.for(section).translated_before_grading? && !response.translated?(section)

    "#{section} (no saved translation, so graded as written)"
  end

  # DailyPlan.for rolls the day's shape at random on every call, so each
  # candidate would otherwise be sent a different request.
  def with_fixed_plan(plan)
    original = DailyPlan.method(:for)
    DailyPlan.define_singleton_method(:for) { |*, **| plan }
    yield
  ensure
    DailyPlan.define_singleton_method(:for, original)
  end

  def print_runs(mode, heading, runs)
    @out.puts "=== #{mode}: #{heading} ==="
    runs.each do |run|
      @out.puts "--- #{run.route[:model]}#{" (effort: #{run.route[:effort]})" if run.route[:effort]} · " \
                "#{format("%.1f", run.seconds)}s#{over_generation_timeout(mode, run)} · " \
                "#{run.tokens_in} in / #{run.tokens_out} out ---"
      @out.puts run.output.is_a?(String) ? run.output : JSON.pretty_generate(run.output)
    end
    @out.puts
  end

  def over_generation_timeout(mode, run)
    return "" unless mode == "generate" && run.seconds > AiService::GENERATION_READ_TIMEOUT

    " (over the #{AiService::GENERATION_READ_TIMEOUT}s generation read timeout)"
  end
end
