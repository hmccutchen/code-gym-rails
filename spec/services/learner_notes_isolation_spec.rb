require "rails_helper"

RSpec.describe "Learner notes isolation" do
  let(:guarded) { /\bLearner(?:Note|Item)\b|\blearner_(?:notes?|items?)\b/ }

  it "matches the singular and plural names it guards" do
    expect([ "has_one :learner_note", "exercise.learner_note.body", "has_one :learner_item", "user.learner_notes" ])
      .to all(match(guarded))
    expect("learner_notes_enabled").not_to match(guarded)
  end

  it "keeps learner notes and items to their own models, the user, the set's association and the account deletion list" do
    own = %w[app/models/learner_note.rb app/models/learner_item.rb app/models/user.rb app/models/account_data.rb
             app/models/daily_exercise.rb]

    readers = (isolation_scope - own).select do |file|
      File.read(Rails.root.join(file)).match?(guarded)
    end
    expect(readers).to eq([])
  end

  describe "the question pickers" do
    let(:pickers) { %w[app/models/note_question.rb] }

    it "take values only: no record, table, mastery, rung, track or trial state" do
      Rails.application.eager_load!
      records = ApplicationRecord.descendants.filter_map(&:name)
      forbidden = /\b(?:#{Regexp.union(records).source}|ApplicationRecord|ActiveRecord)\b|\brungs?\b|\btrack|trial|\.(?:where|find_by|pluck)\b/

      pickers.each do |file|
        expect(File.read(Rails.root.join(file))).not_to match(forbidden), "#{file} reads more than values"
      end
    end
  end

  it "keeps ConceptMastery out of every file added for learner notes" do
    added = %w[app/clients/learner_notes.rb app/controllers/concerns/learner_notes_gate.rb
               app/controllers/concerns/learner_note_questions.rb app/controllers/learner_notes_controller.rb
               app/models/note_question.rb app/views/shared/_learner_note.html.erb
               app/views/accounts/_learner_notes.html.erb app/javascript/controllers/learner_note_controller.js]

    added.each { |file| expect(File.read(Rails.root.join(file))).not_to include("ConceptMastery"), file }
  end
end
