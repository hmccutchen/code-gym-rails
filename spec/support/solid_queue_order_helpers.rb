module SolidQueueOrderHelpers
  def move_to_solid_queue(job_hashes)
    job_hashes.each do |job_hash|
      job = job_hash["job_class"].constantize.new(*ActiveJob::Arguments.deserialize(job_hash["arguments"]))
      job.priority = job_hash["priority"]
      SolidQueue::Job.enqueue(job)
    end
  end

  def solid_queue_claim_order(queue_name)
    worker = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
                                         hostname: "localhost", last_heartbeat_at: Time.current)
    Array.new(SolidQueue::ReadyExecution.queued_as(queue_name).count) do
      SolidQueue::ReadyExecution.claim([ queue_name ], 1, worker.id).sole.job.class_name
    end
  end
end
