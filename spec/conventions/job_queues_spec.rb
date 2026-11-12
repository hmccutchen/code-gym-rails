require "rails_helper"

RSpec.describe "The queue each job runs on" do
  include ActiveJob::TestHelper

  def provider_queue = "provider_calls"

  def general_queue = "default"

  def parsed(file) = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config", file))

  def worker_environments = parsed("queue.yml").except("default")

  def queues_by_worker(environment) = worker_environments.fetch(environment).fetch("workers").map { |worker| Array(worker.fetch("queues")) }

  def job_files = Dir[Rails.root.join("app/jobs/**/*_job.rb")].reject { |path| File.basename(path) == "application_job.rb" }

  def job_class(path) = File.basename(path, ".rb").camelize.constantize

  def job_classes = job_files.map { |path| job_class(path) }

  def provider_job_classes = job_files.select { |path| File.read(path).include?("AiService") }.map { |path| job_class(path) }

  def mailer_queue = ApplicationMailer.deliver_later_queue_name || ActiveJob::Base.default_queue_name

  def recurring_tasks = parsed("recurring.yml").values.flat_map(&:to_a)

  def recurring_queue((key, options))
    SolidQueue::RecurringTask.from_configuration(key, **options.symbolize_keys).enqueue(at: Time.current).queue_name
  end

  def queues_in_use = (job_classes.map(&:queue_name) + recurring_tasks.map { |task| recurring_queue(task) } << mailer_queue).uniq

  it "finds the job classes, the provider jobs among them and an environment block to check" do
    expect(job_classes).to include(GenerateDailyExercisesJob, EnqueueDueGenerationsJob, SendPushReminderJob, SweepDuckThreadsJob)
    expect(provider_job_classes).to contain_exactly(GenerateDailyExercisesJob, RegenerateExerciseJob,
                                                    GenerateConceptReferenceJob, GenerateRecognitionGuideJob)
    expect(worker_environments.keys).to include("production", "development", "test")
  end

  it "serves every job's queue, every recurring task's queue and the mailer queue with a worker in every environment" do
    unserved = worker_environments.keys.to_h { |environment| [ environment, queues_in_use - queues_by_worker(environment).flatten ] }

    expect(unserved.reject { |_environment, queues| queues.empty? }).to eq({})
  end

  it "puts every job that calls a provider on the provider queue, and no other job there" do
    expect(provider_job_classes.map(&:queue_name).uniq).to eq([ provider_queue ])
    expect((job_classes - provider_job_classes).map(&:queue_name).uniq).to eq([ general_queue ])
    expect(mailer_queue).to eq(general_queue)
  end

  it "runs the hourly hand-out, which calls no provider, on the general queue in every environment that schedules it" do
    hand_outs = recurring_tasks.select { |_key, options| options.fetch("class") == "EnqueueDueGenerationsJob" }

    expect(EnqueueDueGenerationsJob.queue_name).to eq(general_queue)
    expect(hand_outs.size).to eq(parsed("recurring.yml").size)
    expect(hand_outs.map { |task| recurring_queue(task) }.uniq).to eq([ general_queue ])
    expect(hand_outs.map { |_key, options| options.keys }.flatten).not_to include("queue")
  end

  it "schedules no provider job directly, so a recurring task never lands on the provider queue" do
    expect(recurring_tasks.map { |_key, options| options.fetch("class") } & provider_job_classes.map(&:name)).to eq([])
  end

  it "gives each queue a worker of its own, so no worker takes both and none takes a wildcard" do
    worker_environments.each_key do |environment|
      workers = queues_by_worker(environment)

      expect(workers.flatten.grep(/\*/)).to eq([]), "#{environment} has a wildcard worker"
      expect(workers.select { |queues| ([ provider_queue, general_queue ] - queues).empty? }).to eq([]), "#{environment} has a worker on both queues"
      expect(workers.flatten).to include(provider_queue, general_queue)
    end
  end
end
