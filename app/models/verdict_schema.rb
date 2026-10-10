# Shared by both judges; a schema can't require non-empty arrays or bound strings, so each .parse stays the boundary.
module VerdictSchema
  def self.one_per_status(statuses)
    { "anyOf" => statuses.map { |status| closed_object({ "status" => { "const" => status } }.merge(yield(status))) } }
  end

  def self.closed_object(properties, required: properties.keys)
    { "type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false }
  end
end
