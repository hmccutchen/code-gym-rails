require "rails_helper"
require Rails.root.join("lib/boot/database_pool")

RSpec.describe DatabasePool do
  def queue_worker_threads
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml"))
      .fetch("production").fetch("workers").map { |worker| worker.fetch("threads") }.max
  end

  def configured_pool(env)
    stub_const("ENV", env)
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/database.yml")).fetch("production").fetch("pool")
  end

  it "holds every worker thread's judge fan-out with nothing set in the environment" do
    needed = queue_worker_threads * (1 + ExerciseSection.slot_count) + DatabasePool::SOLID_QUEUE_OWN_CONNECTIONS

    expect(configured_pool({})).to be >= needed
  end

  it "reads the fan-out from the section registry's count" do
    expect(DatabasePool::SECTIONS_PER_DAY).to eq(ExerciseSection.slot_count)
  end

  it "lets RAILS_MAX_THREADS raise the pool but never lower it below the fan-out" do
    floor = configured_pool({})

    expect(configured_pool("RAILS_MAX_THREADS" => "3")).to eq(floor)
    expect(configured_pool("RAILS_MAX_THREADS" => (floor + 5).to_s)).to eq(floor + 5)
  end
end
