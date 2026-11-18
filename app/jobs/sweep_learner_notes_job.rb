class SweepLearnerNotesJob < ApplicationJob
  queue_as :default

  def perform
    expire_overdue_open_items
    LearnerNote.expired.delete_all
    LearnerItem.expired_after_close.delete_all
  end

  private

  def expire_overdue_open_items
    LearnerItem.owners_with_overdue_open_items.find_each do |user|
      LearnerItem.under_owner_lock(user) { |owner, today| LearnerItem.expire_overdue!(owner, today: today) }
    end
  end
end
