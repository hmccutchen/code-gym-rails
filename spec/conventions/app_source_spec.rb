require "rails_helper"

RSpec.describe "Conventions held over app/ source" do
  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  SESSION_CALLS = %i[session reset_session].freeze
  SESSION_PARAMETERS = [ Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::RequiredKeywordParameterNode,
                         Prism::OptionalKeywordParameterNode, Prism::RestParameterNode, Prism::KeywordRestParameterNode,
                         Prism::BlockParameterNode ].freeze

  def session_reach?(node)
    (node.is_a?(Prism::CallNode) && SESSION_CALLS.include?(node.name)) ||
      (SESSION_PARAMETERS.any? { |type| node.is_a?(type) } && node.name == :session)
  end

  def session_reaches(source)
    found = []
    visit = lambda do |node|
      found << node.location.start_line if session_reach?(node)
      node.compact_child_nodes.each(&visit)
    end
    visit.call(Prism.parse(source).value)
    found.uniq
  end

  it "keeps models off the controller session, which a controller concern reads and hands them as plain values" do
    offenders = Dir[Rails.root.join("app/models/**/*.rb")].sort.flat_map do |path|
      session_reaches(File.read(path)).map { |line| "#{relative(path)}:#{line}" }
    end

    expect(offenders).to be_empty, "Models reaching a controller session: #{offenders.join(', ')}"
  end

  it "finds a session read or a session parameter, and not a session stamp or a word in a comment or string" do
    expect(session_reaches("session[:user_id]")).to eq([ 1 ])
    expect(session_reaches("x = request.session.delete(:pending_trial)")).to eq([ 1 ])
    expect(session_reaches("reset_session")).to eq([ 1 ])
    expect(session_reaches("def self.stash(session, email:) = nil")).to eq([ 1 ])
    expect(session_reaches("def stash(email:, session: nil) = nil")).to eq([ 1 ])
    expect(session_reaches("each { |session| session }")).to eq([ 1 ])
    expect(session_reaches(<<~RUBY)).to be_empty
      # session[:user_id]
      label = "session"
      User.session_time(stamp)
      user.session_signed_in_valid?(signed_in_at)
      update!(sessions_valid_after: now)
      record_review!(response, sections: [], apply_session_countdown: true)
      def self.signed_in_through(user_id:, signed_in_at:) = nil
    RUBY
  end

  it "fails the model that took the session as an argument before #531, whatever its methods are called" do
    renamed_pending_trial = <<~RUBY
      class PendingTrial
        KEY = :pending_trial

        def self.stash(session, email:, invite:, provider:, consented_at:)
          session[KEY] = { "email" => email, "invite_code_id" => invite.id,
                           "provider" => provider, "consented_at" => consented_at.iso8601 }
        end

        def self.discard(session) = session.delete(KEY)

        def self.claim(session)
          data = session.delete(KEY)
          new(data) if data.is_a?(Hash)
        end
      end
    RUBY

    expect(session_reaches(renamed_pending_trial)).to eq([ 4, 9, 11 ])
  end

  LEVEL_FIELDS = %i[skill_level section_kind_levels].freeze
  LEVEL_UPDATES = %i[update update! update_columns update_column update_attribute assign_attributes].freeze
  LEVEL_WRITE_EXEMPT = {
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
      "Only User#choose_track may assign a level directly; ProfileUpdate records the cutoffs and events: #{counts}"
  end

  it "finds a level write however it is spelled, and not a read" do
    expect(level_writes("user.update!(skill_level: 'senior')").size).to eq(1)
    expect(level_writes("user.update_column(:section_kind_levels, {})").size).to eq(1)
    expect(level_writes("self.skill_level = level").size).to eq(1)
    expect(level_writes("user.assign_attributes('section_kind_levels' => {})").size).to eq(1)
    expect(level_writes("rungs(skill_level: user.skill_level); User.new(skill_level: 'junior')").size).to eq(0)
  end

  it "sends every page request through CodeGymRequest, the one place that calls fetch" do
    scripts = Dir[Rails.root.join("app/{javascript,assets/javascripts}/**/*.js")].sort
    offenders = scripts.reject { |path| relative(path) == "app/javascript/code_gym/request.js" }.select do |path|
      File.read(path).match?(/(?<![\w.])fetch\s*\(|\bwindow\.fetch\b|XMLHttpRequest/)
    end

    expect(offenders.map { |path| relative(path) }).to be_empty, "fetch outside request.js: #{offenders.map { |path| relative(path) }.join(', ')}"
  end
end
