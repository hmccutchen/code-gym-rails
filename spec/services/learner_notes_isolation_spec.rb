require "rails_helper"

RSpec.describe "Learner notes isolation" do
  it "keeps learner notes and items to their own models, the user and the account deletion list" do
    own = %w[app/models/learner_note.rb app/models/learner_item.rb app/models/user.rb app/models/account_data.rb]

    readers = (isolation_scope - own).select do |file|
      File.read(Rails.root.join(file)).match?(/\bLearner(?:Note|Item)\b|\blearner_(?:notes|items)\b/)
    end
    expect(readers).to eq([])
  end
end
