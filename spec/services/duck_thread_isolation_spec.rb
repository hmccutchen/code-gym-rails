require "rails_helper"

RSpec.describe "Duck thread isolation" do
  it "keeps stored duck threads out of generation, review, the judges, mastery and planning" do
    files = isolation_scope +
            %w[app/models/concept_mastery.rb app/models/judge_verdict.rb app/models/review_prose_verdict.rb
               app/models/kind_difficulty.rb app/models/daily_response.rb]

    readers = (files - %w[app/jobs/sweep_duck_threads_job.rb]).select do |file|
      File.read(Rails.root.join(file)).match?(/DuckThread|duck_threads\b|\.duck_thread\b/)
    end
    expect(readers).to eq([])
  end
end
