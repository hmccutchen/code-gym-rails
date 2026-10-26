module GlossaryStubHelpers
  def stub_glossary(terms)
    stub_const("Glossary::TERMS", terms)
    stub_const("Glossary::TERM_PATTERN", Glossary.pattern_for(terms))
  end
end

RSpec.configure do |config|
  config.include GlossaryStubHelpers, type: :request
  config.include GlossaryStubHelpers, type: :helper
end
