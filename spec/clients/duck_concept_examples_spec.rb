require "rails_helper"

RSpec.describe "DuckConceptExamples" do
  it "enables only the exact value 1" do
    stub_env("DUCK_CONCEPT_EXAMPLES" => "1")

    expect(DuckConceptExamples.enabled?).to be(true)
  end

  [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
    it "stays off for #{value.inspect}" do
      stub_env("DUCK_CONCEPT_EXAMPLES" => value)

      expect(DuckConceptExamples.enabled?).to be(false)
    end
  end
end
