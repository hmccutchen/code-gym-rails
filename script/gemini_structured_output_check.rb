# Billed to the key it is given; writes no ApiUsage rows.
class GeminiStructuredOutputCheck
  FIXTURE_DIR = Rails.root.join("spec/fixtures/judge")

  # One blind-solve kind and one not, so both schema variants are sent in two requests.
  DEFAULT_FIXTURES = %w[design_comparison_senior_valid code_review_underdetermined].freeze

  Row = Data.define(:name, :outcome, :detail, :tokens_out) do
    def schema_accepted? = %i[parsed invalid].include?(outcome)
  end

  def self.fixture_names = Dir[FIXTURE_DIR.join("*.json")].map { |path| File.basename(path, ".json") }.sort

  def initialize(api_key:, fixtures: DEFAULT_FIXTURES, out: $stdout)
    unknown = fixtures - self.class.fixture_names
    raise ArgumentError, "unknown fixtures: #{unknown.join(', ')}" if unknown.any?

    @api_key  = api_key
    @fixtures = fixtures
    @out      = out
  end

  def run
    rows = @fixtures.map { |name| check(name) }
    rows.each { |row| @out.puts format("%-40s %-8s %6s  %s", row.name, row.outcome, row.tokens_out, row.detail) }
    @out.puts "Schema accepted on #{rows.count(&:schema_accepted?)} of #{rows.size}; " \
              "verdict parsed on #{rows.count { |row| row.outcome == :parsed }}."
    rows
  end

  private

  def check(name)
    fixture = JSON.parse(File.read(FIXTURE_DIR.join("#{name}.json")))
    usage   = []
    verdict = service(usage).judge_section(nil, ExerciseSection.for(fixture["kind"]), fixture["section"],
                                           rung: fixture["rung"], locked: fixture["locked"])
    Row.new(name: name, outcome: :parsed, detail: "status=#{verdict.status}", tokens_out: usage.sum)
  rescue JudgeVerdict::Invalid => e
    Row.new(name: name, outcome: :invalid, detail: e.message, tokens_out: usage.sum)
  rescue AiService::Error => e
    outcome = e.http_status.to_i.between?(400, 499) ? :refused : :error
    Row.new(name: name, outcome: outcome, detail: "#{e.class} #{e.http_status}: #{e.message}", tokens_out: usage.sum)
  end

  # One attempt per fixture: a retry would spend the free tier's daily budget on the same fixture.
  def service(usage)
    Class.new(GeminiService) do
      define_method(:call) { |**kwargs| super(**kwargs.merge(single_attempt: true)) }
      define_method(:log_usage) { |_user, result, purpose:| usage << result[:output_tokens].to_i }
      private :call, :log_usage
    end.new(@api_key)
  end
end
