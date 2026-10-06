require "optparse"

# Replays realistic tester-days against one Gemini key, with the production
# prompts and sizes, until the provider answers 429, and reports how many
# requests that took and which limit was hit. Billed to the key it is given;
# writes no ApiUsage rows and no exercise, response or reference. Nothing in
# app/ loads this, and it never runs in CI.
#
# One tester-day is a judged two-section day plus the calls a person makes
# on it: the draft, one judge call per fixed section, the review's grading
# fan-out with its difficulty check, a first-exposure concept reference, and
# a few thinking-partner turns.
class GeminiCapacityProbe
  DUCK_TURNS = 3
  DUCK_MESSAGES = [
    "I'm not sure where to start with this one.",
    "Is the problem in how the data is fetched?",
    "What would you look at first?"
  ].freeze
  SAMPLE_ANSWER = "The loop fetches related records one row at a time; load them together before the loop instead.".freeze

  # Pacing keeps the per-minute limit out of the way so the daily limit is the
  # one that trips: the wait before a step is the pace times the requests on
  # either side of it, so a fan-out that sends three calls together is given
  # three paces before and after. At 15 seconds no rolling minute holds more
  # than five requests.
  DEFAULT_PACE_SECONDS = 15
  # The probe's connection has no retry middleware, so the longest a request
  # can stay on the wire is one connect and one read. A step waits that long
  # for its stragglers, so a late reply is never counted against the next one.
  DRAIN_SECONDS = AiService.single_attempt_call_seconds(AiService::READ_TIMEOUT)
  OUTPUT_DIR = "tmp/gemini_probe".freeze
  FIXTURE_CAPTURE = "gemini_429_capture.json".freeze

  Record = Data.define(:day, :step, :status, :ms, :input_tokens, :output_tokens, :thought_tokens, :cached_tokens,
                       :quota_id, :quota_value, :retry_delay, :retry_after, :error) do
    def rate_limited? = status == 429
    def ok? = status.to_i.between?(200, 299)
    def tokens = input_tokens.to_i + output_tokens.to_i + thought_tokens.to_i
  end

  # Every HTTP attempt as the provider answered it, shared by every service
  # thread of a step. A step reads its attempts only once none is still on
  # the wire: the review's difficulty thread can outlive review_sections by
  # its grace period, and its reply belongs to the review, not the next step.
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

  # Records every HTTP attempt as the provider answered it, so the report
  # counts requests the way the quota does. The response body is kept only
  # for a non-2xx reply, where it names the quota; a successful reply is
  # reduced to its usage block.
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
                    ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end
    ensure
      @log.abandon! unless recorded
    end
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
    # In memory only: a two-section plan without touching the stored setting.
    @user.daily_section_count = SectionCount::FLOOR
  end

  # In the user's zone, as generation runs: the day, and so the language of
  # a mixed account, is theirs rather than the server's.
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

  # Returns false once a 429 has ended the run.
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

  # One step of a tester-day: paced, recorded per HTTP attempt, and never
  # fatal except on a 429, which is what the probe is looking for. A reply
  # the app could not use still counted against the quota, so it is recorded
  # and the day goes on.
  def step(day, label, requests: 1)
    @sleeper.call(@pace * [ @last_step_attempts, requests, 1 ].max) if @pace.positive? && @calls_made.positive?
    @calls_made += 1
    outcome = yield
    record_attempts(day, label, nil)
    outcome
  rescue AiService::RateLimitError => e
    record_attempts(day, label, e)
    @stopped = true
    nil
  rescue AiService::Error, JudgeVerdict::Invalid => e
    record_attempts(day, label, e)
    nil
  end

  def stopped? = @stopped

  # The review fan-out answers no error of its own, so a 429 inside it is
  # read off the attempts rather than raised.
  def record_attempts(day, label, error)
    fresh = @attempts.drain(timeout: DRAIN_SECONDS)
    @last_step_attempts = fresh.size
    @stopped = true if fresh.any? { |attempt| attempt[:status] == 429 }
    if fresh.empty?
      @records << Record.new(day: day, step: label, status: nil, ms: nil, input_tokens: nil, output_tokens: nil, thought_tokens: nil,
                             cached_tokens: nil, quota_id: nil, quota_value: nil, retry_delay: nil, retry_after: nil,
                             error: error && "#{error.class.name.demodulize}: #{error.message}")
      return
    end
    fresh.each_with_index do |attempt, index|
      record = record_for(day, fresh.size > 1 ? "#{label} [#{index + 1}]" : label, attempt, error)
      @records << record
      capture(attempt, record) unless record.ok?
      @out.puts format_record(record)
    end
  end

  def record_for(day, label, attempt, error)
    body  = attempt[:body].to_s.lstrip.start_with?("{") ? JSON.parse(attempt[:body]) : {}
    usage = body.fetch("usage", {})
    quota = quota_violation(body)
    Record.new(
      day: day, step: label, status: attempt[:status], ms: attempt[:ms],
      input_tokens: usage["total_input_tokens"], output_tokens: usage["total_output_tokens"],
      thought_tokens: usage["total_thought_tokens"], cached_tokens: usage["total_cached_tokens"],
      quota_id: quota["quotaId"], quota_value: quota["quotaValue"],
      retry_delay: retry_info(body), retry_after: attempt[:headers]["retry-after"],
      error: attempt[:status].to_i.between?(200, 299) && error ? "#{error.class.name.demodulize}: #{error.message}" : nil
    )
  rescue JSON::ParserError
    Record.new(day: day, step: label, status: attempt[:status], ms: attempt[:ms], input_tokens: nil, output_tokens: nil,
               thought_tokens: nil, cached_tokens: nil, quota_id: nil, quota_value: nil, retry_delay: nil,
               retry_after: attempt[:headers]["retry-after"], error: "unreadable body")
  end

  def error_details(body, type)
    Array(body.dig("error", "details")).select { |detail| detail.is_a?(Hash) && detail["@type"].to_s.end_with?(type) }
  end

  def quota_violation(body)
    error_details(body, "QuotaFailure").flat_map { |detail| Array(detail["violations"]) }.find { |v| v.is_a?(Hash) } || {}
  end

  def retry_info(body)
    error_details(body, "RetryInfo").filter_map { |detail| detail["retryDelay"] }.first
  end

  # The full body and response headers of a refused reply, for reading and
  # for replacing spec/fixtures/provider_errors, one file per attempt.
  # Request headers are never captured, and a rejected key's body is left
  # out, since Google's API_KEY_INVALID reply can echo the key.
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
    @out.puts "Requests made: #{@records.count { |r| r.status }}."
    if first
      hit = @records[first]
      @out.puts "First 429 on request #{first + 1}: #{limit_kind(hit.quota_id)} (quotaId=#{hit.quota_id}, quotaValue=#{hit.quota_value})."
      @out.puts "Retry delay returned: retryDelay=#{hit.retry_delay.inspect}, Retry-After=#{hit.retry_after.inspect}."
      @out.puts "Tester-days per quota day: #{tester_days_per_quota_day(hit)}."
    else
      @out.puts "No 429 reached."
    end
    @out.puts "Tokens per completed tester-day: #{tokens_per_completed_day.inspect}."
    @out.puts "Largest single request: #{@records.filter_map(&:input_tokens).max.inspect} input tokens."
  end

  def limit_kind(quota_id)
    case quota_id.to_s
    when /PerMinute/i then "per-minute limit"
    when /PerDay/i    then "per-day limit"
    when /Token/i     then "token limit"
    else                   "unrecognized limit"
    end
  end

  def tester_days_per_quota_day(hit)
    return "not a daily limit" unless hit.quota_id.to_s.match?(/PerDay/i)
    return "unknown (no quotaValue)" unless hit.quota_value.to_s.match?(/\A\d+\z/)

    hit.quota_value.to_i / self.class.calls_per_day
  end

  # Days whose last step got an answer, so the figure never counts a day the
  # 429 cut short.
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
