# Words the Learn filter also matches; read only by LearnSearchHelper, so nothing here reaches a provider.
module LearnSearchTerms
  SYNONYMS = {
    "n_plus_one" => [ "n+1", "eager loading" ],
    "sql_injection_prevention" => %w[sqli],
    "xss_prevention" => [ "cross-site scripting" ],
    "mass_assignment_protection" => [ "strong params" ],
    "god_object" => [ "god class" ],
    "off_by_one_boundary" => %w[fencepost],
    "hooks_dependencies" => [ "useeffect", "dependency array" ],
    "concurrency" => [ "race condition" ],
    "open_closed" => %w[solid],
    "dependency_inversion" => %w[solid],
    "this_binding" => [ "this keyword" ]
  }.freeze

  def self.for(key)
    SYNONYMS.fetch(key, [])
  end
end
