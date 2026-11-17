require "rails_helper"

RSpec.describe "Learner notes isolation" do
  let(:guarded) { /\bLearner(?:Note|Item)\b|\blearner_(?:notes?|items?)\b/ }

  it "matches the singular and plural names it guards" do
    expect([ "has_one :learner_note", "exercise.learner_note.body", "has_one :learner_item", "user.learner_notes" ])
      .to all(match(guarded))
    expect("learner_notes_enabled").not_to match(guarded)
  end

  it "keeps learner notes and items to their own models, the user and the account deletion list" do
    own = %w[app/models/learner_note.rb app/models/learner_item.rb app/models/user.rb app/models/account_data.rb]

    readers = (isolation_scope - own).select do |file|
      File.read(Rails.root.join(file)).match?(guarded)
    end
    expect(readers).to eq([])
  end
end
