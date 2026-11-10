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
        def self.planted_http = ApplicationController
        def self.planted_view = ApplicationHelper
        def self.planted_request = params
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

  EXPECTED = [
    [ "app/clients/planted_client.rb", "clients must not depend on controllers" ],
    [ "app/clients/planted_client.rb", "clients must not reference Thread" ],
    [ "app/controllers/planted_controller.rb", "controllers must not reference Thread" ],
    [ "app/forms/planted_form.rb", "forms must not depend on services" ],
    [ "app/helpers/planted_helper.rb", "helpers must not depend on services" ],
    [ "app/jobs/planted_job.rb", "jobs must not depend on controllers" ],
    [ "app/mailers/planted_mailer.rb", "mailers must not depend on services" ],
    [ "app/models/ai_provider.rb", "provider_registry must not call #params" ],
    [ "app/models/ai_provider.rb", "provider_registry must not call #send" ],
    [ "app/models/ai_provider.rb", "provider_registry must not depend on controllers" ],
    [ "app/models/ai_provider.rb", "provider_registry must not depend on helpers" ],
    [ "app/models/ai_provider.rb", "provider_registry must not depend on services" ],
    [ "app/models/ai_provider.rb", "provider_registry must not reference Thread" ],
    [ "app/models/planted_model.rb", "models must not call #call" ],
    [ "app/models/planted_model.rb", "models must not call #send" ],
    [ "app/models/planted_model.rb", "models must not depend on clients" ],
    [ "app/models/planted_model.rb", "models must not depend on jobs" ],
    [ "app/models/planted_model.rb", "models must not depend on services" ],
    [ "app/models/planted_model.rb", "models must not reference Faraday" ],
    [ "app/models/planted_model.rb", "models must not reference Thread" ],
    [ "app/prompts/planted_prompt.rb", "prompts must not depend on clients" ],
    [ "app/services/planted_service.rb", "services must not reference Faraday" ]
  ].freeze

  def violations_with_plants(plants = PLANTS)
    Dir.mktmpdir do |root|
      FileUtils.cp(Rails.root.join("Archspec.rb"), root)
      FileUtils.cp_r(Rails.root.join("app"), root)
      plants.each { |path, source| File.write(File.join(root, path), source, mode: path.end_with?("ai_provider.rb") ? "a" : "w") }

      output, status = Open3.capture2(RbConfig.ruby, Gem.bin_path("archspec", "archspec"), "check", "--format", "json",
                                      "--config", File.join(root, "Archspec.rb"))
      expect(status.exitstatus).to eq(1), output
      JSON.parse(output).fetch("violations")
    end
  end

  it "reports each planted break by its own ban, and nothing in the code that is already there" do
    bans = violations_with_plants.reject { |violation| violation["rule"] == "dependencies.no_cycles" }
    found = bans.map { |violation| [ violation["path"], violation["message"] ] }.uniq.sort

    expect(found).to eq(EXPECTED.sort), "unexpected: #{found - EXPECTED}\nmissing: #{EXPECTED - found}"
  end

  it "reports a service that reaches back into a job at the service's own line, and as a loop" do
    plant = { "app/services/planted_service.rb" => "class PlantedService\n  def self.job = GenerateDailyExercisesJob\nend\n" }
    found = violations_with_plants(plant).map { |violation| [ violation["path"], violation["line"], violation["message"] ] }

    expect(found).to include([ "app/services/planted_service.rb", 2, "services must not depend on jobs" ])
    expect(found.map(&:last)).to include("component dependency cycle: jobs -> services -> jobs")
  end

  it "reports a loop through the prompt classes, which sit outside the Rails preset" do
    plants = { "app/models/planted_model.rb" => "class PlantedModel\n  def self.prompt = PlantedPrompt\nend\n",
               "app/prompts/planted_prompt.rb" => "class PlantedPrompt\n  def self.model = PlantedModel\nend\n" }

    expect(violations_with_plants(plants).map { |violation| violation["rule"] }).to include("dependencies.no_cycles")
  end

  it "puts every Ruby folder under app/ in a component, so no folder escapes the bans" do
    folders = Rails.root.glob("app/*/**/*.rb").map { |path| path.relative_path_from(Rails.root).each_filename.to_a[1] }.uniq
    declared = File.read(Rails.root.join("Archspec.rb")).scan(%r{"app/(\w+)/\*\*/\*\.rb"}).flatten

    expect(folders - declared).to be_empty, "app/ folders with no component in Archspec.rb: #{(folders - declared).join(', ')}"
  end
end
