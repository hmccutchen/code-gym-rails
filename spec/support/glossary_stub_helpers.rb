module GlossaryStubHelpers
  def stub_glossary(terms, forms = {})
    stub_const("Glossary::TERMS", terms)
    stub_const("Glossary::FORMS", forms)
    stub_const("Glossary::TERM_PATTERN", Glossary.pattern_for(terms, forms))
    stub_const("Glossary::LOOKUP", Glossary.lookup_for(terms, forms))
  end
end

RSpec.configure do |config|
  config.include GlossaryStubHelpers, type: :request
  config.include GlossaryStubHelpers, type: :helper
end
