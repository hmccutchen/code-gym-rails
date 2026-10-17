class SweepDuckThreadsJob < ApplicationJob
  queue_as :default

  def perform
    DuckThread.expired.delete_all
  end
end
