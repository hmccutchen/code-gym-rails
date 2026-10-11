require "rails_helper"

RSpec.describe "Conventions held over app/ source" do
  THREAD_EXEMPT = {
    "app/services/caller_zone_thread.rb" => "the one place a fan-out thread is started",
    "app/models/code_format/javascript.rb" => "pipe readers for Prettier that touch neither Time.zone nor the database"
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

  it "starts every thread through CallerZoneThread, so a fan-out keeps the caller's zone" do
    offenders = app_files.reject { |path| THREAD_EXEMPT.key?(relative(path)) }.flat_map do |path|
      calls_in(path).select { |call| call.name == :new && call.receiver.is_a?(Prism::ConstantReadNode) && call.receiver.name == :Thread }
                    .map { |call| "#{relative(path)}:#{call.location.start_line}" }
    end

    expect(offenders).to be_empty, "Thread.new outside CallerZoneThread: #{offenders.join(', ')}"
  end

  it "keeps every exemption pointing at a file that still starts a thread" do
    THREAD_EXEMPT.each_key do |path|
      starts = calls_in(Rails.root.join(path).to_s).any? { |call| call.name == :new && call.receiver&.slice == "Thread" }
      expect(starts).to be(true), "#{path} no longer starts a thread; drop its exemption"
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
