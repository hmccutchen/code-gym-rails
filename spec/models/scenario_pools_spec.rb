require "rails_helper"

RSpec.describe ScenarioPools do
  describe "GENERAL_DOMAINS" do
    it "is a frozen list of exactly these 9 scenario flavors, including a rare legacy-GraphQL entry" do
      expect(described_class::GENERAL_DOMAINS).to be_frozen
      expect(described_class::GENERAL_DOMAINS.size).to eq(9)
      expect(described_class::GENERAL_DOMAINS).to contain_exactly(
        "background_job_processing", "api_versioning_and_deprecation",
        "activerecord_query_construction", "component_state_management",
        "data_export_and_reporting", "webhook_delivery", "rate_limiting",
        "multi_tenant_data_isolation", "legacy_graphql_maintenance"
      )
    end

    it "is never mixed into any tracked concept vocabulary" do
      expect(described_class::GENERAL_DOMAINS & ConceptVocabulary::RAILS_CONCEPTS).to be_empty
      expect(described_class::GENERAL_DOMAINS & ConceptVocabulary::JS_CONCEPTS).to be_empty
      expect(described_class::GENERAL_DOMAINS & ConceptVocabulary::ARCHITECTURE_CONCEPTS).to be_empty
    end
  end

  describe "EVERYDAY_DOMAINS" do
    it "is a frozen, non-empty pool disjoint from the other pools and every concept vocabulary" do
      pool = described_class::EVERYDAY_DOMAINS

      expect(pool).to be_frozen
      expect(pool).not_to be_empty
      expect(pool & described_class::GENERAL_DOMAINS).to be_empty
      [ ConceptVocabulary::RAILS_CONCEPTS, ConceptVocabulary::JS_CONCEPTS, ConceptVocabulary::ARCHITECTURE_CONCEPTS,
        ConceptVocabulary::PLAN_REVIEW_CONCEPTS, ConceptVocabulary::AMBIGUITY_HUNT_CONCEPTS ].each do |vocabulary|
        expect(pool & vocabulary).to be_empty
      end
    end

    it "names nothing from a company's back office" do
      back_office = %w[invoice invoicing ledger tenant csv webhook payroll billing export graphql api]

      described_class::EVERYDAY_DOMAINS.each do |domain|
        expect(domain.split("_") & back_office).to be_empty, "#{domain} names back-office context"
      end
    end

    it "is rolled under exactly the flavors DailyPlan weights" do
      expect(described_class::ALL.keys).to match_array(DailyPlan::SCENARIO_FLAVOR_WEIGHTS.keys)
      expect(described_class::ALL.dig(:general, :domains)).to equal(described_class::GENERAL_DOMAINS)
      expect(described_class::ALL.dig(:everyday, :domains)).to equal(described_class::EVERYDAY_DOMAINS)
    end
  end
end
