# Design notes: docs/code-notes/script/concept_reference_calibration.md
class ConceptReferenceCalibration
  PROVIDERS = {
    "claude" => { service: ClaudeService, key: "ANTHROPIC_API_KEY" },
    "gemini" => { service: GeminiService, key: "GEMINI_API_KEY" }
  }.freeze
  PURPOSE = "generate_concept_reference".freeze
  BUCKETS = (ConceptBucket.language_buckets_for("mixed") + ConceptBucket::LANGUAGE_INDEPENDENT).freeze
  CONCEPTS_PER_BUCKET = 2

  Record = Data.define(:provider, :model, :bucket, :concept, :mode, :seconds, :outcome, :measured, :tokens_in, :tokens_out, :attempts)

  # The counter sits inside faraday-retry, so a retried call reports every attempt the provider saw.
  class RequestProbe
    attr_reader :attempts, :model

    def initialize
      @attempts = 0
    end

    def record(env)
      @attempts += 1
      @model = JSON.parse(env.request_body)["model"]
    end
  end

  class AttemptCounter
    def initialize(app, probe)
      @app   = app
      @probe = probe
    end

    def call(env)
      @probe.record(env)
      @app.call(env)
    end
  end

  # Fixed rather than random so two runs measure the same prompts; tradeoff concepts get a different worked example.
  def self.default_sample
    BUCKETS.flat_map do |bucket|
      vocabulary = ConceptBucket.vocabulary_for(bucket)
      picks      = vocabulary.first(CONCEPTS_PER_BUCKET)
      tradeoff   = ((vocabulary & AiService::TRADEOFF_CONCEPTS) - picks).first
      (picks + [ tradeoff ].compact).map { |concept| [ bucket, concept ] }
    end
  end

  def self.key_variable_for(provider)
    PROVIDERS.dig(provider, :key)
  end

  def initialize(provider:, api_key:, out: $stdout, timeout: AiService::CONCEPT_REFERENCE_READ_TIMEOUT,
                 repeats: 2, concurrency: 6)
    @provider_class = PROVIDERS.fetch(provider) { raise ArgumentError, "provider must be one of #{PROVIDERS.keys.join(', ')}" }[:service]
    validate_options!(timeout, repeats, concurrency)
    @provider       = provider
    @api_key        = api_key
    @out            = out
    @timeout        = timeout
    @repeats        = repeats
    @concurrency    = concurrency
    @print_lock     = Mutex.new
  end

  def run(sample = self.class.default_sample)
    validate!(sample)
    @out.puts "Timing covers the provider call only, including faraday retries and their backoff. " \
              "Queue wait and persistence are excluded, because the service is called directly. " \
              "Post-response validation failures count in both measured and failures."
    records = sequential_phase(sample) + concurrent_phase(sample)
    print_summary(records)
    records
  end

  def summary(records)
    records.group_by(&:mode).transform_values { |group| mode_summary(group) }
  end

  private

  def validate_options!(timeout, repeats, concurrency)
    unless timeout > AiService::READ_TIMEOUT
      raise ArgumentError, "timeout must exceed AiService::READ_TIMEOUT (#{AiService::READ_TIMEOUT}s), " \
                           "or the retry guard stops treating a timeout as final and retries it"
    end
    raise ArgumentError, "repeats must be 0 or more" if repeats.negative?
    raise ArgumentError, "concurrency must be 0 or more" if concurrency.negative?
  end

  def validate!(sample)
    sample.each do |bucket, concept|
      vocabulary = BUCKETS.include?(bucket) ? ConceptBucket.vocabulary_for(bucket) : []
      next if vocabulary.include?(concept)

      raise ArgumentError, "#{bucket}/#{concept} is not a concept in that bucket's vocabulary"
    end
  end

  def sequential_phase(sample)
    (sample * @repeats).map { |bucket, concept| measure(bucket, concept, :sequential) }
  end

  def concurrent_phase(sample)
    return [] if @concurrency.zero?

    sample.first(@concurrency).map { |bucket, concept| Thread.new { measure(bucket, concept, :concurrent) } }.map(&:value)
  end

  def measure(bucket, concept, mode)
    probe   = RequestProbe.new
    usage   = []
    service = pinned_service(probe, usage)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome, measured = call_outcome { service.generate_concept_reference(User.new, concept, bucket) }
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    Record.new(provider: @provider, model: probe.model, bucket: bucket, concept: concept, mode: mode,
               seconds: seconds, outcome: outcome, measured: measured, attempts: probe.attempts,
               tokens_in: usage.sum { |row| row[:tokens_in] }, tokens_out: usage.sum { |row| row[:tokens_out] })
      .tap { |record| print_record(record) }
  end

  def call_outcome
    yield
    [ :ok, true ]
  rescue AiService::TimeoutError
    [ :timeout, true ]
  rescue AiService::InvalidResponseError => e
    [ e.class.name, true ]
  rescue AiService::Error => e
    [ e.class.name, false ]
  end

  # Leaves the route alone, since the deployed route is what is measured; only the read timeout is replaceable.
  def pinned_service(probe, usage)
    timeout = @timeout

    Class.new(@provider_class) do
      define_method(:call) do |**options|
        options[:read_timeout] = timeout if options[:purpose] == PURPOSE
        super(**options)
      end
      define_method(:build_connection) { super().tap { |conn| conn.builder.use(AttemptCounter, probe) } }
      define_method(:log_usage) do |_user, result, purpose:|
        usage << { tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i }
      end
      define_method(:record_suggested_concept) { |_suggestion| }
      private :call, :build_connection, :log_usage, :record_suggested_concept
    end.new(@api_key)
  end

  def print_record(record)
    @print_lock.synchronize do
      @out.puts "#{record.provider} #{record.model} · #{record.bucket}/#{record.concept} · #{record.mode} · " \
                "#{format_seconds(record.seconds)} · #{record.outcome} · " \
                "#{record.attempts} #{record.attempts == 1 ? 'attempt' : 'attempts'} · " \
                "#{record.tokens_in} in / #{record.tokens_out} out"
    end
  end

  def print_summary(records)
    summary(records).each do |mode, stats|
      @out.puts "#{mode}: n=#{stats[:n]} measured=#{stats[:measured]} min=#{format_seconds(stats[:min])} median=#{format_seconds(stats[:median])} " \
                "p90=#{format_seconds(stats[:p90])} max=#{format_seconds(stats[:max])} " \
                "timeouts=#{stats[:timeouts]} failures=#{stats[:failures]} " \
                "over #{AiService::CONCEPT_REFERENCE_READ_TIMEOUT}s (CONCEPT_REFERENCE_READ_TIMEOUT)=#{stats[:over_deployed]}"
    end
  end

  # Refusals and transport failures don't measure generation time; an invalid reply does, and also counts as a failure.
  def mode_summary(records)
    measured = records.select(&:measured)
    seconds  = measured.map(&:seconds).sort

    { n:             records.size,
      measured:      measured.size,
      min:           seconds.first,
      median:        percentile(seconds, 50),
      p90:           percentile(seconds, 90),
      max:           seconds.last,
      timeouts:      records.count { |record| record.outcome == :timeout },
      failures:      records.count { |record| record.outcome.is_a?(String) },
      over_deployed: measured.count { |record| record.seconds > AiService::CONCEPT_REFERENCE_READ_TIMEOUT } }
  end

  def percentile(sorted, pct)
    return if sorted.empty?

    sorted[((sorted.size * pct / 100.0).ceil - 1).clamp(0, sorted.size - 1)]
  end

  def format_seconds(seconds)
    seconds ? "#{format('%.1f', seconds)}s" : "n/a"
  end
end
