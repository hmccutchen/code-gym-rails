require "rails_helper"

RSpec.describe "Duck thread isolation" do
  it "keeps stored duck threads out of generation, review, the judges, mastery and planning" do
    own = %w[app/jobs/sweep_duck_threads_job.rb app/models/duck_thread.rb app/models/daily_exercise.rb app/models/user.rb]

    readers = (isolation_scope - own).select do |file|
      File.read(Rails.root.join(file)).match?(/DuckThread|duck_threads\b|\.duck_thread\b/)
    end
    expect(readers).to eq([])
  end
end
