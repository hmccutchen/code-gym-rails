# Builds the structured-output schemas the judges' replies are held to: one
# alternative per status, every object closed. One home for both judges,
# because the provider's schema rules are one fact whichever verdict they
# shape. A schema cannot require a non-empty array or bound a string, so each
# verdict's .parse remains the boundary.
module VerdictSchema
  def self.one_per_status(statuses)
    { "anyOf" => statuses.map { |status| closed_object({ "status" => { "const" => status } }.merge(yield(status))) } }
  end

  def self.closed_object(properties, required: properties.keys)
    { "type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false }
  end
end
