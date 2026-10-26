module GlossaryStubHelpers
  def stub_glossary(terms)
    stub_const("Glossary::TERMS", terms)
    stub_const("Glossary::TERM_PATTERN",
      Regexp.union(terms.keys.sort_by { |t| -t.length }.map { |t| /\b#{Regexp.escape(t)}\b/i }))
  end
end

RSpec.configure do |config|
  config.include GlossaryStubHelpers, type: :request
end
