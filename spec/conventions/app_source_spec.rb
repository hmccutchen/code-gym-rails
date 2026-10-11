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
end
