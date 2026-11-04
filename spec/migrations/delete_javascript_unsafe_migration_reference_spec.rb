require "rails_helper"
require Rails.root.join("db/migrate/20261104120000_delete_javascript_unsafe_migration_reference").to_s

RSpec.describe DeleteJavascriptUnsafeMigrationReference do
  def migrate_up = ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

  def reference(concept, language) = ConceptReference.create!(concept: concept, language: language, tagline: "t")

  it "deletes the JavaScript unsafe_migration reference, written before the prompt said it was a schema concept" do
    reference("unsafe_migration", "javascript")

    migrate_up

    expect(ConceptReference.where(concept: "unsafe_migration", language: "javascript")).to be_empty
  end

  it "keeps the Ruby row and the other JavaScript data-modeling rows" do
    kept = [ reference("unsafe_migration", "ruby_rails") ] +
           (ConceptVocabulary::DATA_MODELING_CONCEPTS - [ "unsafe_migration" ]).map { |concept| reference(concept, "javascript") }

    migrate_up

    expect(kept.map { |row| ConceptReference.exists?(row.id) }).to all(be(true))
  end
end
