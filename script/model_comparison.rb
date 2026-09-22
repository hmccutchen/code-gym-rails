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
    "translate" => [ { model: "claude-sonnet-5" }, { model: "claude-haiku-4-5" } ]
  }.freeze

  REVIEW_FIELDS = %w[rating missed next_step].freeze

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

  private

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
