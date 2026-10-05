# Read-only. Prints which request parameters the app's own filter_parameters
# masks in request logs and which it lets through.
#
#   bin/rails runner script/security_audit/parameter_filter_check.rb
filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

sample = {
  "email" => "someone@example.com",
  "code" => "123456",
  "api_key" => "sk-ant-not-a-real-key",
  "user" => { "name" => "A name", "api_keys" => { "anthropic" => "sk-ant-not-a-real-key" } },
  "response" => { "answers" => { "code_review" => "an answer" } },
  "message" => "a duck message",
  "question" => "a follow-up question",
  "pseudocode" => "a plan",
  "prior_alternates" => [ "an earlier framing" ],
  "p256dh" => "push key",
  "auth" => "push auth secret",
  "endpoint" => "https://fcm.googleapis.com/fcm/send/abc"
}

filtered = filter.filter(sample)

def leaves(hash, prefix = nil)
  hash.flat_map do |key, value|
    path = [ prefix, key ].compact.join(".")
    case value
    when Hash then leaves(value, path)
    when Array then value.map { |item| [ path, item ] }
    else [ [ path, value ] ]
    end
  end
end

leaves(filtered).each do |path, value|
  puts format("%-32s %s", path, value == "[FILTERED]" ? "filtered" : "LOGGED")
end
