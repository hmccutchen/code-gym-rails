require "rails_helper"
require Rails.root.join("db/migrate/20261029120000_clear_non_hash_concept_lessons").to_s

RSpec.describe ClearNonHashConceptLessons do
  def migrate_up = ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

  def reference_with_lesson(concept, lesson)
    ConceptReference.create!(concept: concept, language: "ruby_rails").tap { |row| row.update_columns(lesson: lesson) }
  end

  it "clears a lesson stored as a string, number or list" do
    rows = { "over_mocking" => "None", "error_handling" => 42, "background_jobs" => [ "definition" ] }
             .map { |concept, lesson| reference_with_lesson(concept, lesson) }

    migrate_up

    expect(rows.map { |row| row.reload.lesson }).to all(be_nil)
  end

  it "keeps a lesson stored as a hash, and a row with no lesson" do
    kept = reference_with_lesson("closures", { "definition" => "d" })
    empty = reference_with_lesson("memoization", nil)

    migrate_up

    expect(kept.reload.lesson).to eq("definition" => "d")
    expect(empty.reload.lesson).to be_nil
  end
end
