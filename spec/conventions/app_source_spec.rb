require "rails_helper"

RSpec.describe "Conventions held over app/ source" do
  THREAD_EXEMPT = {
    "app/services/caller_zone_thread.rb" => { threads: 1, reason: "the one place a fan-out thread is started" },
    "app/models/code_format/javascript.rb" => { threads: 2, reason: "Prettier's stdout and stderr readers, which touch neither Time.zone nor the database" }
  }.freeze

  def calls_in(path)
    found = []
    visit = lambda do |node|
      found << node if node.is_a?(Prism::CallNode)
      node.compact_child_nodes.each(&visit)
    end
    visit.call(Prism.parse_file(path).value)
    found
  end

  def app_files = Dir[Rails.root.join("app/**/*.rb")].sort

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def thread_starts(path)
    calls_in(path).select { |call| call.name == :new && call.receiver.is_a?(Prism::ConstantReadNode) && call.receiver.name == :Thread }
  end

  it "starts every thread through CallerZoneThread, so a fan-out keeps the caller's zone" do
    offenders = app_files.reject { |path| THREAD_EXEMPT.key?(relative(path)) }.flat_map do |path|
      thread_starts(path).map { |call| "#{relative(path)}:#{call.location.start_line}" }
    end

    expect(offenders).to be_empty, "Thread.new outside CallerZoneThread: #{offenders.join(', ')}"
  end

  it "holds each exempt file to exactly the threads its exemption names" do
    THREAD_EXEMPT.each do |path, exemption|
      count = thread_starts(Rails.root.join(path).to_s).size
      expect(count).to eq(exemption[:threads]), "#{path} starts #{count} threads; its exemption covers #{exemption[:threads]} (#{exemption[:reason]})"
    end
  end

  it "never reaches a private method through send" do
    offenders = app_files.flat_map do |path|
      calls_in(path).select { |call| %i[send __send__].include?(call.name) && call.arguments&.arguments&.first.is_a?(Prism::SymbolNode) }
                    .map { |call| "#{relative(path)}:#{call.location.start_line}" }
    end

    expect(offenders).to be_empty, "send(:...) in app/: #{offenders.join(', ')}"
  end

  PROVIDER_REGISTRY = "app/models/ai_provider.rb".freeze

  def provider_class_names = @provider_class_names ||= ([ AiService ] + AiProvider.all).map { |klass| klass.name.to_sym }

  def provider_class_name?(node)
    (node.is_a?(Prism::ConstantReadNode) || (node.is_a?(Prism::ConstantPathNode) && node.parent.nil?)) &&
      provider_class_names.include?(node.name)
  end

  def provider_class_references(source)
    found = []
    visit = lambda do |node|
      if node.is_a?(Prism::ConstantPathNode) && provider_class_name?(node.parent)
        found << "#{node.parent.name}::#{node.name}"
        next
      end
      found << node.name.to_s if provider_class_name?(node)
      node.compact_child_nodes.each(&visit)
    end
    visit.call(Prism.parse(source).value)
    found
  end

  it "keeps models off the provider classes, apart from the registry" do
    offenders = Dir[Rails.root.join("app/models/**/*.rb")].sort.reject { |path| relative(path) == PROVIDER_REGISTRY }.flat_map do |path|
      provider_class_references(File.read(path)).map { |reference| "#{relative(path)}: #{reference}" }
    end

    expect(offenders).to be_empty, "Models naming a provider class: #{offenders.join(', ')}"
  end

  it "finds a provider class however the reference is written, and not in a comment or a string" do
    expect(provider_class_references("AiService.for(user)")).to eq([ "AiService" ])
    expect(provider_class_references("::AiService::LANGUAGE_PROMPTS")).to eq([ "AiService::LANGUAGE_PROMPTS" ])
    expect(provider_class_references("X = GeminiService.daily_quota_reset_at(at)")).to eq([ "GeminiService" ])
    expect(provider_class_references("class Probe < ClaudeService; end")).to eq([ "ClaudeService" ])
    expect(provider_class_references("# AiService::LANGUAGE_PROMPTS\nlabel = \"AiService\"")).to be_empty
  end
end
