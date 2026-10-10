require "optparse"

# Design notes: docs/code-notes/script/gemini_capacity_probe.md
class GeminiCapacityProbe
  DUCK_TURNS = 3
  DUCK_MESSAGES = [
    "I'm not sure where to start with this one.",
    "Is the problem in how the data is fetched?",
    "What would you look at first?"
  ].freeze
  SAMPLE_ANSWER = "The loop fetches related records one row at a time; load them together before the loop instead.".freeze

  DEFAULT_PACE_SECONDS = 15
  # No retry middleware, so one connect and one read is the longest a straggler can take.
  DRAIN_SECONDS = AiService.single_attempt_call_seconds(AiService::READ_TIMEOUT)
  OUTPUT_DIR = "tmp/gemini_probe".freeze
  FIXTURE_CAPTURE = "gemini_429_capture.json".freeze

  Record = Data.define(:day, :step, :sent, :status, :ms, :input_tokens, :output_tokens, :thought_tokens, :cached_tokens,
                       :quota_id, :quota_value, :retry_delay, :retry_after, :error) do
    def rate_limited? = status == 429
    def ok? = status.to_i.between?(200, 299)
    def tokens = input_tokens.to_i + output_tokens.to_i + thought_tokens.to_i
  end

  # Read only once nothing is on the wire: the review's difficulty thread can outlive review_sections.
  class AttemptLog
    def initialize
      @attempts  = []
      @in_flight = 0
      @lock      = Mutex.new
    end

    def start! = @lock.synchronize { @in_flight += 1 }

    def record(attempt) = @lock.synchronize { @attempts << attempt; @in_flight -= 1 }

    def abandon! = @lock.synchronize { @in_flight -= 1 }

    def in_flight = @lock.synchronize { @in_flight }

    def drain(timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep(0.1) while in_flight.positive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      @lock.synchronize { @attempts.shift(@attempts.size) }
    end
  end

  # Records attempts that got no reply too, since the provider may have counted them against the quota.
  class Recorder < Faraday::Middleware
    def initialize(app, log)
      super(app)
      @log = log
    end

    def call(env)
      @log.start!
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      recorded = false
      @app.call(env).on_complete do |response|
        recorded = true
        @log.record(status: response.status, headers: response.response_headers.to_h, body: response.body.to_s,
                    ms: elapsed_ms(started))
      end
    rescue StandardError => e
      unless recorded
        recorded = true
        @log.record(status: nil, headers: {}, body: "", ms: elapsed_ms(started), error: e.class.name)
      end
      raise
    ensure
      @log.abandon! unless recorded
    end

    private

    def elapsed_ms(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end

  def self.calls_per_day = 1 + ExerciseSection.fixed.size + ExerciseSection.fixed.size + 1 + 1 + DUCK_TURNS

  def initialize(api_key:, user:, pace: DEFAULT_PACE_SECONDS, max_days: nil, out: $stdout,
                 output_dir: Rails.root.join(OUTPUT_DIR), adapter: [ :net_http ], sleeper: ->(seconds) { sleep(seconds) })
    @api_key    = api_key
    @user       = user
    @pace       = pace
    @max_days   = max_days
    @out        = out
    @output_dir = Pathname(output_dir)
    @adapter    = adapter
    @sleeper    = sleeper
    @attempts   = AttemptLog.new
    @records    = []
    @captured   = 0
    @calls_made = 0
    @last_step_attempts = 0
    @user.daily_section_count = SectionCount::FLOOR
  end

  def run
    Time.use_zone(@user.effective_time_zone) do
      @output_dir.mkpath
      @out.puts "Probing with user #{@user.id} (#{language}); #{self.class.calls_per_day} calls per tester-day, pace #{@pace}s."
      day = 0
      loop do
        day += 1
        break if @max_days && day > @max_days
        break unless tester_day(day)
      end
      print_report
    end
    @records
  end

  private

  def language = @user.language_for_today

  def tester_day(day)
    @out.puts "--- tester-day #{day}"
    draft = step(day, "draft") { service.send(:draft_exercise, @user, language: language, blocking: false) }
    return false if stopped?
    return true if draft.nil?

    judge(day, draft) && review(day, draft) && reference(day, draft) && duck(day, draft)
  end

  def judge(day, draft)
    ExerciseSection.fixed.each do |kind|
      section = draft.problem_set[kind.key] or next
      step(day, "judge #{kind.key}") do
        service.judge_section(@user, kind, section, rung: draft.difficulty.rung_for(kind, skill_level: @user.skill_level),
                                                   locked: draft.difficulty.locked?(kind))
      end
      return false if stopped?
    end
    true
  end

  def review(day, draft)
    exercise = DailyExercise.new(user: @user, date: Date.current, problem_set: draft.problem_set,
                                 language: language, generated_at: Time.current)
    sections = exercise.active_section_keys
    response = DailyResponse.new(user: @user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                                 answers: sections.index_with { |key| sample_answer(key) },
                                 section_ratings: sections.index_with { "right_level" })
    step(day, "review (#{sections.size} grading + difficulty)", requests: sections.size + 1) do
      service.review_sections(@user, exercise, response, sections: sections)
    end
    !stopped?
  end

  def reference(day, draft)
    concept = draft.problem_set.dig(ExerciseSection::CodeReview.key, "concept").presence || "other"
    step(day, "reference #{concept}") { service.generate_concept_reference(@user, concept, language) }
    !stopped?
  end

  def duck(day, draft)
    exercise = DailyExercise.new(user: @user, date: Date.current, problem_set: draft.problem_set, language: language)
    thread   = []
    DUCK_MESSAGES.first(DUCK_TURNS).each_with_index do |message, turn|
      answer = step(day, "duck turn #{turn + 1}") do
        service.duck_response(@user, exercise, section: ExerciseSection::CodeReview.key, message: message, thread: thread)
      end
      return false if stopped?

      thread += [ { role: "user", content: message }, { role: "assistant", content: answer.to_s } ]
    end
    true
  end

  def sample_answer(key)
    kind = ExerciseSection.for(key)
    kind.respond_to?(:encode_answer) ? kind.encode_answer("a", SAMPLE_ANSWER) : SAMPLE_ANSWER
  end

  def step(day, label, requests: 1)
    @sleeper.call(@pace * [ @last_step_attempts, requests, 1 ].max) if @pace.positive? && @calls_made.positive?
    @calls_made += 1
    outcome = yield
    record_attempts(day, label, nil)
    outcome
  rescue AiService::RateLimitError => e
    record_attempts(day, label, e)
    @stop_reason ||= :rate_limited
    nil
  rescue AiService::AuthenticationError => e
    record_attempts(day, label, e)
    @stop_reason ||= :key_refused
    nil
  rescue AiService::Error, JudgeVerdict::Invalid => e
    record_attempts(day, label, e)
    nil
  end

  def stopped? = @stop_reason.present?

  def record_attempts(day, label, error)
    fresh = @attempts.drain(timeout: DRAIN_SECONDS)
    @last_step_attempts = fresh.size
    @stop_reason ||= :rate_limited if fresh.any? { |attempt| attempt[:status] == 429 }
    @stop_reason ||= :key_refused if fresh.any? { |attempt| key_rejected?(attempt) }
    if fresh.empty?
      @records << Record.new(day: day, step: label, sent: false, status: nil, ms: nil, input_tokens: nil, output_tokens: nil, thought_tokens: nil,
                             cached_tokens: nil, quota_id: nil, quota_value: nil, retry_delay: nil, retry_after: nil,
                             error: error && "#{error.class.name.demodulize}: #{error.message}")
      return
    end
    fresh.each_with_index do |attempt, index|
      record = record_for(day, fresh.size > 1 ? "#{label} [#{index + 1}]" : label, attempt, error)
      @records << record
      capture(attempt, record) unless record.ok? || record.status.nil?
      @out.puts format_record(record)
    end
  end

  def record_for(day, label, attempt, error)
    body  = attempt[:body].to_s.lstrip.start_with?("{") ? JSON.parse(attempt[:body]) : {}
    usage = body.fetch("usage", {})
    quota = quota_violation(body)
    Record.new(
      day: day, step: label, sent: true, status: attempt[:status], ms: attempt[:ms],
      input_tokens: usage["total_input_tokens"], output_tokens: usage["total_output_tokens"],
      thought_tokens: usage["total_thought_tokens"], cached_tokens: usage["total_cached_tokens"],
      quota_id: quota["quotaId"], quota_value: quota["quotaValue"],
      retry_delay: retry_info(body), retry_after: attempt[:headers]["retry-after"],
      error: attempt_error(attempt, error)
    )
  rescue JSON::ParserError
    Record.new(day: day, step: label, sent: true, status: attempt[:status], ms: attempt[:ms], input_tokens: nil, output_tokens: nil,
               thought_tokens: nil, cached_tokens: nil, quota_id: nil, quota_value: nil, retry_delay: nil,
               retry_after: attempt[:headers]["retry-after"], error: "unreadable body")
  end

  def attempt_error(attempt, error)
    return "no reply: #{attempt[:error]}" if attempt[:status].nil?

    "#{error.class.name.demodulize}: #{error.message}" if attempt[:status].to_i.between?(200, 299) && error
  end

  def error_details(body, type)
    Array(body.dig("error", "details")).select { |detail| detail.is_a?(Hash) && detail["@type"].to_s.end_with?(type) }
  end

  def quota_violation(body)
    violations = error_details(body, "QuotaFailure").flat_map { |detail| Array(detail["violations"]) }.select { |v| v.is_a?(Hash) }
    violations.find { |v| v["quotaId"].to_s.match?(ProviderFailure::DAILY_QUOTA_PATTERN) } || violations.first || {}
  end

  def retry_info(body)
    error_details(body, "RetryInfo").filter_map { |detail| detail["retryDelay"] }.first
  end

  # Never captures request headers or a rejected key's body: Google's API_KEY_INVALID reply can echo the key.
  def capture(attempt, record)
    stamp = Time.current.utc.strftime("%Y%m%dT%H%M%S")
    path  = @output_dir.join("#{stamp}-#{format('%03d', @captured += 1)}-#{record.status}.json")
    body  = key_rejected?(attempt) ? "[omitted: an authentication error can echo the key]" : attempt[:body]
    path.write(JSON.pretty_generate(status: record.status, headers: attempt[:headers], body: body))
    if record.rate_limited? && !@output_dir.join(FIXTURE_CAPTURE).exist?
      @output_dir.join(FIXTURE_CAPTURE).write(attempt[:body])
    end
    @out.puts "  wrote #{path}"
  end

  def key_rejected?(attempt)
    [ 401, 403 ].include?(attempt[:status]) || attempt[:body].to_s.include?("API_KEY_INVALID")
  end

  def format_record(record)
    tokens = record.ok? ? "in=#{record.input_tokens} out=#{record.output_tokens} thought=#{record.thought_tokens} cached=#{record.cached_tokens}" : ""
    quota  = record.rate_limited? ? "quotaId=#{record.quota_id} quotaValue=#{record.quota_value} retryDelay=#{record.retry_delay} Retry-After=#{record.retry_after}" : ""
    format("  day %-2d %-36s %3s %6sms  %s%s%s", record.day, record.step, record.status, record.ms, tokens, quota,
           record.error ? "  #{record.error}" : "")
  end

  def print_report
    first = @records.index(&:rate_limited?)
    @out.puts "=== report"
    @out.puts "Requests made: #{@records.count(&:sent)}."
    if first
      hit = @records[first]
      @out.puts "First 429 on request #{first + 1}: #{limit_kind(hit.quota_id)} (quotaId=#{hit.quota_id}, quotaValue=#{hit.quota_value})."
      @out.puts "Retry delay returned: retryDelay=#{hit.retry_delay.inspect}, Retry-After=#{hit.retry_after.inspect}."
      @out.puts "Tester-days per quota day: #{tester_days_per_quota_day(hit)}."
    elsif @stop_reason == :key_refused
      @out.puts "Stopped before any 429: Gemini refused the key."
    else
      @out.puts "No 429 reached."
    end
    @out.puts "Tokens per completed tester-day: #{tokens_per_completed_day.inspect}."
    @out.puts "Largest single request: #{@records.filter_map(&:input_tokens).max.inspect} input tokens."
  end

  def limit_kind(quota_id)
    case quota_id.to_s
    when /PerMinute/i then "per-minute limit"
    when ProviderFailure::DAILY_QUOTA_PATTERN then "per-day limit"
    when /Token/i     then "token limit"
    else                   "unrecognized limit"
    end
  end

  def tester_days_per_quota_day(hit)
    return "not a daily limit" unless hit.quota_id.to_s.match?(ProviderFailure::DAILY_QUOTA_PATTERN)
    return "unknown (no quotaValue)" unless hit.quota_value.to_s.match?(/\A\d+\z/)

    hit.quota_value.to_i / self.class.calls_per_day
  end

  def tokens_per_completed_day
    completed = @records.group_by(&:day).select { |_, rows| rows.size >= self.class.calls_per_day && rows.none?(&:rate_limited?) }
    completed.transform_values { |rows| rows.sum(&:tokens) }
  end

  def service
    log     = @attempts
    adapter = @adapter
    @service ||= Class.new(GeminiService) do
      define_method(:log_usage) { |_user, _result, purpose:| }
      define_method(:build_connection) do
        Faraday.new do |f|
          f.options.open_timeout      = AiService::OPEN_TIMEOUT
          f.options.timeout           = AiService::READ_TIMEOUT
          f.headers["x-goog-api-key"] = @api_key
          f.headers["content-type"]   = "application/json"
          f.use Recorder, log
          f.adapter(*adapter)
        end
      end
      private :log_usage, :build_connection
    end.new(@api_key)
  end
end
