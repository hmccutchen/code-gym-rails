require "rails_helper"
require "open3"

RSpec.describe "Archspec.rb rules" do
  PLANTS = {
    "app/models/planted_model.rb" => <<~RUBY,
      class PlantedModel
        def self.thread = Thread.new { 1 }
        def self.connection = Faraday.new
        def self.reach(record) = record.send(:secret)
        def self.draft = ExerciseDraft.call(nil)
        def self.provider = AiService
        def self.side_effect = ResponseReview
        def self.job = GenerateDailyExercisesJob
      end
    RUBY
    "app/models/ai_provider.rb" => <<~RUBY,
      class AiProvider
        def self.planted_thread = Thread.new { 1 }
        def self.planted_reach(record) = record.send(:secret)
        def self.planted_side_effect = ResponseReview
      end
    RUBY
    "app/prompts/planted_prompt.rb" => "class PlantedPrompt\n  def self.provider = ClaudeService\nend\n",
    "app/clients/planted_client.rb" => "class PlantedClient\n  def self.thread = Thread.new { 1 }\n  def self.http = ApplicationController\nend\n",
    "app/services/planted_service.rb" => "class PlantedService\n  def self.connection = Faraday.new\nend\n",
    "app/controllers/planted_controller.rb" => "class PlantedController\n  def thread = Thread.new { 1 }\nend\n",
    "app/jobs/planted_job.rb" => "class PlantedJob\n  def perform = ApplicationController\nend\n",
    "app/mailers/planted_mailer.rb" => "class PlantedMailer\n  def welcome = ResponseReview\nend\n",
    "app/forms/planted_form.rb" => "class PlantedForm\n  def save = ResponseReview\nend\n",
    "app/helpers/planted_helper.rb" => "module PlantedHelper\n  def planted = ResponseReview\nend\n"
  }.freeze

  EXPECTED = {
    "app/models/planted_model.rb" => %w[constants.forbid methods.forbid dependencies.forbid],
    "app/models/ai_provider.rb" => %w[constants.forbid methods.forbid dependencies.forbid],
    "app/prompts/planted_prompt.rb" => %w[dependencies.forbid],
    "app/clients/planted_client.rb" => %w[constants.forbid dependencies.forbid],
    "app/services/planted_service.rb" => %w[constants.forbid],
    "app/controllers/planted_controller.rb" => %w[constants.forbid],
    "app/jobs/planted_job.rb" => %w[dependencies.forbid],
    "app/mailers/planted_mailer.rb" => %w[dependencies.forbid],
    "app/forms/planted_form.rb" => %w[dependencies.forbid],
    "app/helpers/planted_helper.rb" => %w[dependencies.forbid]
  }.freeze

  def violations_with_plants
    Dir.mktmpdir do |root|
      FileUtils.cp(Rails.root.join("Archspec.rb"), root)
      FileUtils.cp_r(Rails.root.join("app"), root)
      PLANTS.each { |path, source| File.write(File.join(root, path), source, mode: path.end_with?("ai_provider.rb") ? "a" : "w") }

      output, status = Open3.capture2(RbConfig.ruby, Gem.bin_path("archspec", "archspec"), "check", "--format", "json",
                                      "--config", File.join(root, "Archspec.rb"))
      expect(status.exitstatus).to eq(1), output
      JSON.parse(output).fetch("violations")
    end
  end

  it "reports each planted break, and nothing in the code that is already there" do
    found = violations_with_plants.group_by { |violation| violation["path"] }.transform_values { |list| list.map { |v| v["rule"] }.uniq.sort }

    expect(found).to eq(EXPECTED.transform_values(&:sort))
  end

  it "puts every Ruby folder under app/ in a component, so no folder escapes the bans" do
    folders = Rails.root.glob("app/*/**/*.rb").map { |path| path.relative_path_from(Rails.root).each_filename.to_a[1] }.uniq
    declared = File.read(Rails.root.join("Archspec.rb")).scan(%r{"app/(\w+)/\*\*/\*\.rb"}).flatten

    expect(folders - declared).to be_empty, "app/ folders with no component in Archspec.rb: #{(folders - declared).join(', ')}"
  end
end
