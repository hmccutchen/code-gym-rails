# Which params filter_parameters masks in request logs, for one sample of every param a user can send.
class ParameterFilterReport
  SAMPLE = {
    "email" => "someone@example.com",
    "code" => "123456",
    "api_key" => "sk-ant-not-a-real-key",
    "user" => { "name" => "A name", "api_keys" => { "anthropic" => "sk-ant-not-a-real-key" } },
    "response" => { "answers" => { "code_review" => "an answer" } },
    "message" => "a duck message",
    "thread" => [ { "role" => "user", "content" => "an earlier duck turn" } ],
    "question" => "a follow-up question",
    "pseudocode" => "a plan",
    "prior_alternates" => [ "an earlier framing" ],
    "p256dh" => "push key",
    "auth" => "push auth secret",
    "endpoint" => "https://fcm.googleapis.com/fcm/send/abc"
  }.freeze

  def initialize(filter_parameters: Rails.application.config.filter_parameters, out: $stdout)
    @filter = ActiveSupport::ParameterFilter.new(filter_parameters)
    @out = out
  end

  def results
    leaves(@filter.filter(SAMPLE)).map { |path, value| [ path, value == "[FILTERED]" ? :filtered : :logged ] }
  end

  def report
    results.each { |path, outcome| @out.puts format("%-32s %s", path, outcome == :filtered ? "filtered" : "LOGGED") }
  end

  private

  def leaves(hash, prefix = nil)
    hash.flat_map do |key, value|
      path = [ prefix, key ].compact.join(".")
      case value
      when Hash then leaves(value, path)
      when Array then value.flat_map { |item| item.is_a?(Hash) ? leaves(item, path) : [ [ path, item ] ] }
      else [ [ path, value ] ]
      end
    end
  end
end
