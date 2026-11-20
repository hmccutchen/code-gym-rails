module DuckConceptExamples
  ENV_KEY = "DUCK_CONCEPT_EXAMPLES"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
