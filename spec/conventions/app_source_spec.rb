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
    expect(provider_class_references("::AiService::RUBRIC_VERSION")).to eq([ "AiService::RUBRIC_VERSION" ])
    expect(provider_class_references("X = GeminiService.daily_quota_reset_at(at)")).to eq([ "GeminiService" ])
    expect(provider_class_references("class Probe < ClaudeService; end")).to eq([ "ClaudeService" ])
    expect(provider_class_references("# AiService::RUBRIC_VERSION\nlabel = \"AiService\"")).to be_empty
  end

  LEVEL_FIELDS = %i[skill_level section_kind_levels].freeze
  LEVEL_UPDATES = %i[update update! update_columns update_column update_attribute assign_attributes].freeze
  LEVEL_WRITE_EXEMPT = {
    "app/models/level_change.rb" => { writes: 1, reason: "the track change clearing targets inside ProfileUpdate's save" },
    "app/models/user.rb" => { writes: 1, reason: "#choose_track, which ProfileUpdate calls under the row lock" }
  }.freeze

  def level_field?(node) = (node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)) && LEVEL_FIELDS.include?(node.unescaped.to_sym)

  def level_writes(source)
    found = []
    visit = lambda do |node|
      if node.is_a?(Prism::CallNode)
        arguments = node.arguments&.arguments.to_a
        named = arguments.any? { |arg| arg.respond_to?(:elements) && arg.elements.any? { |pair| pair.respond_to?(:key) && level_field?(pair.key) } }
        found << node.location.start_line if LEVEL_FIELDS.any? { |field| node.name == :"#{field}=" } ||
                                              (LEVEL_UPDATES.include?(node.name) && (named || level_field?(arguments.first)))
      end
      node.compact_child_nodes.each(&visit)
    end
    visit.call(Prism.parse(source).value)
    found
  end

  it "changes a saved user's levels only through ProfileUpdate, which records their cutoffs and events" do
    sources = Dir[Rails.root.join("{app,lib,script}/**/*.rb")].sort.to_h { |path| [ relative(path), File.read(path) ] }
    counts = sources.transform_values { |source| level_writes(source).size }.reject { |_path, count| count.zero? }

    expect(counts).to eq(LEVEL_WRITE_EXEMPT.transform_values { |exemption| exemption[:writes] }),
      "Only LevelChange and User#choose_track may write a saved user's levels; ProfileUpdate records the cutoffs and events: #{counts}"
  end

  it "finds a level write however it is spelled, and not a read" do
    expect(level_writes("user.update!(skill_level: 'senior')").size).to eq(1)
    expect(level_writes("user.update_column(:section_kind_levels, {})").size).to eq(1)
    expect(level_writes("self.skill_level = level").size).to eq(1)
    expect(level_writes("user.assign_attributes('section_kind_levels' => {})").size).to eq(1)
    expect(level_writes("rungs(skill_level: user.skill_level); User.new(skill_level: 'junior')").size).to eq(0)
  end
end
