require "rails_helper"

RSpec.describe VerdictSchema do
  describe ".closed_object" do
    it "lists every property as required and allows no others" do
      expect(described_class.closed_object({ "a" => { "type" => "string" } }))
        .to eq("type" => "object", "properties" => { "a" => { "type" => "string" } },
               "required" => [ "a" ], "additionalProperties" => false)
    end

    it "takes an explicit required list for optional properties" do
      expect(described_class.closed_object({ "a" => { "type" => "string" } }, required: [])["required"]).to eq([])
    end
  end

  describe ".one_per_status" do
    it "offers one closed alternative per status, carrying that status as a constant" do
      schema = described_class.one_per_status(%w[keep edit]) { |status| status == "edit" ? { "note" => { "type" => "string" } } : {} }

      expect(schema).to eq("anyOf" => [
        described_class.closed_object({ "status" => { "const" => "keep" } }),
        described_class.closed_object({ "status" => { "const" => "edit" }, "note" => { "type" => "string" } })
      ])
    end
  end

  it "is the one schema builder both judges use" do
    [ JudgeVerdict, ReviewProseVerdict ].each do |verdict|
      expect(verdict.private_methods).not_to include(:closed_object)
      expect(verdict.singleton_class.private_method_defined?(:closed_object)).to be(false)
    end
  end
end
