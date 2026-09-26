# Runs one stored input through two Claude models and prints both results
# side by side, for a person to read and judge. Nothing in app/ loads this.
#
# Calls are billed to the key passed in, never the stored user's own key, and
# usage is kept in memory rather than written as ApiUsage rows, since those
# rows would charge a teammate's history for a comparison they never ran.
class ModelComparison
  CANDIDATES = {
    "generate"  => [ { model: "claude-sonnet-5" }, { model: "claude-opus-5-5", effort: "medium" } ],
    "review"    => [ { model: "claude-sonnet-5" }, { model: "claude-opus-5-5" } ],
    "duck"      => [ { model: "claude-sonnet-5" }, { model: "claude-haiku-4-5" } ],
    "translate" => [ { model: "claude-sonnet-5" }, { model: "claude-haiku-4-5" } ],
    "judge"     => [ { model: "claude-sonnet-5" }, { model: "claude-haiku-4-5" } ]
  }.freeze

  REVIEW_FIELDS = %w[rating missed next_step].freeze
  VERDICT_FIELDS = %w[status issues principle evidence reason].freeze

  FIXTURE_DIR = Rails.root.join("spec/fixtures/judge")

  # List prices as of writing, per million tokens; read nowhere in app/ — this
  # is what #judge_fixtures prices a candidate's run against, for a person
  # comparing them, never anything billed.
  LIST_PRICE_PER_MILLION = {
    "claude-sonnet-5"  => { input: 2.0, output: 10.0 },
    "claude-haiku-4-5" => { input: 1.0, output: 5.0 }
  }.freeze

  Run = Data.define(:route, :output, :seconds, :tokens_in, :tokens_out)

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
      define_method(:route_for) { |_purpose| route }
      define_method(:log_usage) do |_user, result, purpose:|
        lock.synchronize { usage << { tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i } }
      end
      define_method(:record_suggested_concept) { |_suggestion| }
      private :route_for, :log_usage, :record_suggested_concept
    end.new(@api_key)
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
