class ApplicationJob < ActiveJob::Base
  private

  # The account can be deleted while a provider call runs; the job then writes nothing and stops.
  def unless_account_deleted(user)
    yield
  rescue ActiveRecord::RecordNotFound
    raise if User.exists?(user.id)

    Rails.logger.info("Stopped #{self.class.name} for user #{user.id}: the account was deleted")
  end
end
