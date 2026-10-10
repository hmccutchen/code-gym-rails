# Production boot never loads prism, so without this the first real-source pick raises NameError; a spec pins it.
require "prism"

# Design notes: docs/code-notes/app/models/real_source.md
class RealSource
  LANGUAGE = "ruby_rails".freeze

  WEIGHTS = { real: 0.35, toy: 0.65 }.freeze

  MIN_LINES = 5
  MAX_LINES = 40

  class Excerpt
    attr_reader :path

    def initialize(path)
      @path = path
    end

    def id
      path
    end

    def text
      raise NotImplementedError, "#{self.class} must implement #text"
    end

    def scenario
      raise NotImplementedError, "#{self.class} must implement #scenario"
    end

    def instruction
      raise NotImplementedError, "#{self.class} must implement #instruction"
    end

    def resolvable?
      !text.nil?
    end

    def lines
      text&.lines&.size
    end

    def current_schema
      nil
    end

    private

    def absolute_path
      Rails.root.join(path)
    end

    def fenced(language, body = text)
      [ "```#{language}", body.strip_heredoc.chomp, "```" ].join("\n")
    end

    def lines_spanning(source, node)
      source.lines[(node.location.start_line - 1)...node.location.end_line].join
    end

    def receiverless_calls(node, found = [])
      found << node if node.is_a?(Prism::CallNode) && node.receiver.nil?
      node.compact_child_nodes.each { |child| receiverless_calls(child, found) }
      found
    end

    def setting_rule
      "The business-domain settings suggested for each section do not apply to this one: its setting is " \
      "Code Gym itself, a learning app for engineers, so its comments, names, and any other prose describe " \
      "Code Gym, never one of the suggested settings or another fictional domain. " \
      "These source-specific instructions take precedence over the general variety, mastery-loop, " \
      "and retention requests for new domains, names, or framing. " \
      "Keep the required source names and setting even if this excerpt appears in prior framings. " \
      "A retention check may use this excerpt: make the planted flaw a fresh application of the chosen concept, " \
      "rather than relying on renamed identifiers or a new business story for novelty. " \
      "This exception changes neither concept selection nor difficulty; " \
      "all other sections still follow the general freshness rules."
    end
  end

  # Scoped by name, not line range: unrelated edits above a method would shift a range onto the wrong lines.
  class Method < Excerpt
    attr_reader :method

    def initialize(path, method)
      super(path)
      @method = method
    end

    def id
      "#{path}##{method}"
    end

    def text
      return nil unless File.exist?(absolute_path)

      source = File.read(absolute_path)
      node   = find_def(Prism.parse(source).value)
      node && lines_spanning(source, node)
    end

    def scenario
      "Code Gym's own source — `#{path}`, `##{method}` — altered for this exercise. " \
      "The deployed method is fine; find what this copy gets wrong."
    end

    def instruction
      <<~INSTRUCTION.chomp
        - The code_review snippet is a MODIFIED COPY of this real method from Code Gym's own source (`#{id}`). Reproduce its shape, names, and structure as the starting point, then introduce EXACTLY ONE flaw that expresses the chosen concept. Never return it unchanged — there would be nothing to find — and never introduce a second flaw, since grading assumes exactly one. Keep the real class, method, and variable names. #{setting_rule} The scenario field must be exactly: "#{scenario}"

        #{fenced("ruby")}
      INSTRUCTION
    end

    private

    def find_def(node)
      return node if node.is_a?(Prism::DefNode) && node.name.to_s == method

      node.compact_child_nodes.each do |child|
        found = find_def(child)
        return found if found
      end
      nil
    end
  end

  class Migration < Excerpt
    SCHEMA_PATH = "db/schema.rb".freeze

    # Excludes execute (its argument is SQL) and drop/rename_table (their table has left the schema, so it would never resolve).
    TABLE_STATEMENTS = %i[
      create_table change_table
      add_column remove_column rename_column change_column change_column_default change_column_null
      add_index remove_index rename_index add_reference remove_reference add_belongs_to
      add_timestamps remove_timestamps add_foreign_key remove_foreign_key
      add_check_constraint remove_check_constraint
    ].freeze

    def text
      File.exist?(absolute_path) ? File.read(absolute_path) : nil
    end

    def resolvable?
      super && !current_schema.nil?
    end

    def current_schema
      tables = touched_tables
      schema_path = Rails.root.join(SCHEMA_PATH)
      return nil if tables.empty? || !File.exist?(schema_path)

      schema      = File.read(schema_path)
      statements  = receiverless_calls(Prism.parse(schema).value)
      definitions = tables.map { |table| table_definition(schema, statements, table) }
      definitions.all? ? definitions.join("\n") : nil
    end

    def name
      File.basename(path, ".rb").sub(/\A\d+_/, "")
    end

    def scenario
      "Modelled on Code Gym's own migration — `#{name}`. " \
      "This is not that migration; find the data-modeling flaw in this one."
    end

    def instruction
      <<~INSTRUCTION.chomp
        - The code_review snippet is a Rails migration MODELLED ON this real one from Code Gym's own schema history (`#{id}`) — same conventions, same style: a plausible next migration for the same table(s). ~10-15 lines, containing EXACTLY ONE planted data-modeling flaw; never zero, never two. #{setting_rule} The scenario field must be exactly: "#{scenario}"

        #{fenced("ruby")}

        - This is how those table(s) stand today in `db/schema.rb`, and the engineer sees it beside the snippet. The snippet must apply cleanly to it: no column that already exists, and no index whose default name (`index_<table>_on_<columns>`) already exists. The planted flaw is a data-modeling flaw, never a migration that fails to run.

        #{fenced("ruby", current_schema)}
      INSTRUCTION
    end

    private

    def touched_tables
      return [] if text.nil?

      receiverless_calls(Prism.parse(text).value)
        .select { |call| TABLE_STATEMENTS.include?(call.name) }
        .filter_map { |call| table_argument(call) }
        .uniq
    end

    def table_definition(schema, statements, table)
      create = statements.find { |call| call.name == :create_table && table_argument(call) == table }
      return nil if create.nil?

      foreign_keys = statements.select { |call| call.name == :add_foreign_key && table_argument(call) == table }
      [ create, *foreign_keys ].map { |call| lines_spanning(schema, call).strip_heredoc }.join
    end

    def table_argument(call)
      first = call.arguments&.arguments&.first
      first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
    end
  end

  # Never-seen ties drain in list order (see .pick), so append new entries, never insert.
  APPLICATION_CODE = [
    Method.new("app/services/weighted_roll.rb", "pick"),
    Method.new("app/services/section_rotation.rb", "pick_kind"),
    Method.new("app/services/section_count.rb", "for"),
    Method.new("app/models/concept_reference.rb", "claim_feature"),
    Method.new("app/models/user.rb", "carry_forward"),
    Method.new("app/models/user.rb", "authenticate_login_code"),
    Method.new("app/models/user.rb", "current_streak"),
    Method.new("app/models/push_subscription.rb", "register!"),
    Method.new("app/controllers/sessions_controller.rb", "verify_code"),
    Method.new("app/services/ai_service.rb", "flatten_history"),
    Method.new("app/services/ai_service.rb", "annotate_retention_concept"),
    Method.new("app/models/user.rb", "resume_generation!"),
    Method.new("app/models/user.rb", "held_exercise"),
    Method.new("app/models/concept_mastery.rb", "retention_schedule_for"),
    Method.new("app/models/concept_mastery.rb", "record_review!"),
    Method.new("app/services/section_count.rb", "capped_window"),
    Method.new("app/services/daily_plan.rb", "retention_checks_for"),
    Method.new("app/models/daily_response.rb", "improved_code_visible?"),
    Method.new("app/jobs/generate_daily_exercises_job.rb", "generate_if_due"),
    Method.new("app/jobs/send_push_reminder_job.rb", "stage_for"),
    Method.new("app/controllers/daily_exercises_controller.rb", "claim_regeneration!")
  ].freeze

  SCHEMA_REVIEW = [
    Migration.new("db/migrate/20260905120000_create_push_subscriptions.rb"),
    Migration.new("db/migrate/20260908120000_add_reminder_level_to_users.rb"),
    Migration.new("db/migrate/20260911000001_add_featured_on_to_concept_references.rb"),
    Migration.new("db/migrate/20260819153107_add_pseudocode_rounds_to_daily_responses.rb"),
    Migration.new("db/migrate/20260723010000_create_concept_masteries.rb"),
    Migration.new("db/migrate/20260101000003_create_daily_responses.rb"),
    Migration.new("db/migrate/20260723000000_add_section_ratings_to_daily_responses.rb"),
    Migration.new("db/migrate/20260728000004_add_retention_schedule_to_concept_masteries.rb")
  ].freeze

  POOLS = { application_code: APPLICATION_CODE, schema_review: SCHEMA_REVIEW }.freeze

  def self.pool(mode)
    POOLS.fetch(mode, [])
  end

  def self.all
    POOLS.values.flatten
  end

  def self.pick(mode, last_seen:)
    candidates  = pool(mode).select { |excerpt| usable?(excerpt) }
    never, seen = candidates.partition { |excerpt| !last_seen.key?(excerpt.id) }

    never.first || seen.min_by { |excerpt| [ last_seen.fetch(excerpt.id), candidates.index(excerpt) ] }
  end

  def self.last_seen_for(user)
    user.daily_exercises
        .where("problem_set -> 'code_review' ->> 'source' IS NOT NULL")
        .group("problem_set -> 'code_review' ->> 'source'")
        .maximum(:date)
  end

  def self.usable?(excerpt)
    return true if excerpt.resolvable?

    Rails.logger.warn("[real_source] #{excerpt.id} no longer resolves and was skipped")
    false
  end
  private_class_method :usable?
end
