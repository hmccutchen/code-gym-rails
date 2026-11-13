# Design notes: docs/code-notes/app/clients/unfinished_jobs.md
module UnfinishedJobs
  WAITING_EXECUTIONS = [
    SolidQueue::ReadyExecution, SolidQueue::ScheduledExecution, SolidQueue::BlockedExecution, SolidQueue::FailedExecution
  ].freeze

  def self.discard_naming(user_id:, global_ids:)
    unfinished = SolidQueue::Job.where(finished_at: nil).select(:id, :arguments)
    ids = unfinished.find_each.select { |job| names?(job.arguments, user_id, global_ids) }.map(&:id)
    SolidQueue::Job.transaction { SolidQueue::Job.where(id: still_waiting(ids)).delete_all }
  end

  def self.still_waiting(job_ids)
    locked = WAITING_EXECUTIONS.flat_map { |execution| execution.where(job_id: job_ids).order(:job_id).non_blocking_lock.pluck(:job_id) }
    locked - SolidQueue::ClaimedExecution.where(job_id: locked).pluck(:job_id)
  end

  def self.names?(value, user_id, global_ids)
    case value
    when Hash then value["user_id"] == user_id || global_ids.include?(value["_aj_globalid"]) ||
                   value.each_value.any? { |entry| names?(entry, user_id, global_ids) }
    when Array then value.any? { |entry| names?(entry, user_id, global_ids) }
    else false
    end
  end
  private_class_method :still_waiting, :names?
end
