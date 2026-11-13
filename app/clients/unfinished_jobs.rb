# Design notes: docs/code-notes/app/clients/unfinished_jobs.md
module UnfinishedJobs
  def self.discard_naming(user_id:, global_ids:)
    waiting = SolidQueue::Job.where(finished_at: nil).where.not(id: SolidQueue::ClaimedExecution.select(:job_id))
    ids = waiting.select(:id, :arguments).find_each.select { |job| names?(job.arguments, user_id, global_ids) }.map(&:id)
    SolidQueue::Job.where(id: ids).delete_all
  end

  def self.names?(value, user_id, global_ids)
    case value
    when Hash then value["user_id"] == user_id || global_ids.include?(value["_aj_globalid"]) ||
                   value.each_value.any? { |entry| names?(entry, user_id, global_ids) }
    when Array then value.any? { |entry| names?(entry, user_id, global_ids) }
    else false
    end
  end
  private_class_method :names?
end
