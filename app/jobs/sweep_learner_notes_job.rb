class SweepLearnerNotesJob < ApplicationJob
  queue_as :default

  def perform
    LearnerNote.expired.delete_all
    LearnerItem.expired_after_close.delete_all
  end
end
