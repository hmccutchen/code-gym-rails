# Required here rather than trusted to be present: nothing in a production
# boot loads it — only irb, debug, and the lint tooling do, none of which a
# Puma process touches — so without this line the first real-source pick
# raised NameError. A spec loads this file in a production-only bundle to pin
# it.
require "prism"

# Curated excerpts of Code Gym's own source that a code_review may be grounded
# in, in the same shape as ExerciseSection: closed Ruby lists, one class per
# kind of excerpt, and nothing eligible unless deliberately added here. The
# lists exist for exercise QUALITY — not every file makes focused, one-sitting
# material — not for safety: nothing in this source is a per-instance secret,
# and every file is eligible.
#
# Grounding an exercise in this app's own code is the point, not a leak into
# an otherwise generic scenario. Code Gym is a working learning app, and the
# engineer's lived context in it — pausing and resuming a set, a concept coming
# back for a retention check — is what supplies the domain fluency a fictional
# education-app scenario cannot. The safeguards are the ones below: a curated
# list, exactly one planted flaw — in a modified copy of a method, or in a new
# migration modelled on a real one — a scenario that says so, and never the
# unmodified original. Design:
# docs/superpowers/specs/2026-09-11-real-source-code-review-design.md
class RealSource
  # Code Gym is written in Ruby, so the pool can only serve a day generating
  # in that language — a javascript day asks for JS/React code or a Prisma
  # schema, and this codebase has neither.
  LANGUAGE = "ruby_rails".freeze

  # The real-vs-toy sub-roll inside an eligible mode. One constant for both
  # modes: they have no reason to differ, and two would be a second rule that
  # can disagree. Sized so a grounded day lands roughly weekly per mode. How
  # soon a given excerpt comes back is the pool's size divided into that, so
  # growing a pool is what spaces its entries out — the pool is what should
  # grow first, not this.
  WEIGHTS = { real: 0.35, toy: 0.65 }.freeze

  # A one-line migration has no room to plant a flaw; a sixty-line method is
  # not a one-sitting read. A spec holds every entry inside this, so curation
  # cannot quietly drift outside it.
  MIN_LINES = 5
  MAX_LINES = 40

  # One excerpt: what its text is, whether it still resolves against the
  # deployed source, what the scenario line says, what the generation prompt
  # says about it, and the current schema the snippet is written against, if
  # any. Subclasses answer the text, the scenario and the prompt, and override
  # the schema only when their snippet is written against a table. The read is
  # always off local disk, so the text is exactly what is currently deployed.
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

    # A renamed method or a deleted file must not turn into a failed
    # generation for every user until someone edits the list — .pick skips
    # what does not resolve.
    def resolvable?
      !text.nil?
    end

    def lines
      text&.lines&.size
    end

    # Stamped by ProblemSetIngest, shown beside the snippet, and read by the
    # grader, the duck, and the difficulty assessment. Nil for a kind whose
    # snippet is not written against a table.
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
  end

  # A single method, scoped by name and sliced out with Prism. Line ranges
  # were rejected: every unrelated edit above a method would shift them and
  # silently hand the exercise the wrong lines. A name survives edits
  # elsewhere in the file and breaks only when the method itself moves.
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

    # Says the copy is altered, not just where it came from: without that an
    # engineer can read the exercise as a bug report against deployed code.
    def scenario
      "Code Gym's own source — `#{path}`, `##{method}` — altered for this exercise. " \
      "The deployed method is fine; find what this copy gets wrong."
    end

    def instruction
      <<~INSTRUCTION.chomp
        - The code_review snippet is a MODIFIED COPY of this real method from Code Gym's own source (`#{id}`). Reproduce its shape, names, and structure as the starting point, then introduce EXACTLY ONE flaw that expresses the chosen concept. Never return it unchanged — there would be nothing to find — and never introduce a second flaw, since grading assumes exactly one. Keep the real class, method, and variable names; do not rewrite it into a fictional domain. The scenario field must be exactly: "#{scenario}"

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

  # A whole migration file — short enough that the file is the unit. Handed
  # to the model as reference and style, never mutated in place: a one-line
  # add_column has no room for a data-modeling flaw, and the interesting kind
  # is a NEW migration on a real table that gets cardinality or an index
  # wrong. The scenario says "modelled on" for the same reason.
  #
  # A migration file never states everything its table has — `t.references`
  # creates an index it never names, and later migrations can change the table
  # — so the model and the grader also get each table as db/schema.rb has it
  # today. Without that a planted migration can add an index the table already
  # has and fail on the name before its flaw matters. A modified copy of the
  # original is no longer offered: the current table would sit beside it on
  # the page and show the fix.
  class Migration < Excerpt
    SCHEMA_PATH = "db/schema.rb".freeze

    # Schema statements whose first argument is the table they change.
    # `execute` is left out on purpose: its first argument is SQL. So are
    # drop_table and rename_table: the table they name is no longer in the
    # schema, so listing them would make any entry that uses them unresolvable.
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

    # Each touched table's create_table block and its add_foreign_key lines.
    # Nil when a touched table is gone from the schema, or the schema file
    # itself is, which makes the entry unresolvable: there is nothing left to
    # write the next migration against.
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
        - The code_review snippet is a Rails migration MODELLED ON this real one from Code Gym's own schema history (`#{id}`) — same conventions, same style: a plausible next migration for the same table(s). ~10-15 lines, containing EXACTLY ONE planted data-modeling flaw; never zero, never two. The scenario field must be exactly: "#{scenario}"

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

  # Each a real decision with something to get wrong, across several files so
  # no one file dominates. Order matters: ties among never-seen entries drain
  # in this order (see .pick), so new entries are appended, never inserted.
  # The entries from resume_generation! on are the learning-app material —
  # pausing and resuming, spaced repetition, mastery cooldowns, adaptive
  # sizing, gated reveals, reminders — chosen because each reads as any
  # education app's decision, not as Code Gym trivia.
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

  # Chosen for having structure to get wrong: references, constraints, an
  # index, an up/down with a backfill. A bare one-line add_column is not here.
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

  # test_file has no pool by construction, which is what keeps it untouched.
  POOLS = { application_code: APPLICATION_CODE, schema_review: SCHEMA_REVIEW }.freeze

  def self.pool(mode)
    POOLS.fetch(mode, [])
  end

  def self.all
    POOLS.values.flatten
  end

  # The same order SectionRotation gives kinds and ConceptReference.featured
  # gives concepts: an entry this user has never seen outranks every dated
  # one, ties among never-seen drain in list order — a fixed order empties the
  # pool one per pick and bounds the worst-case wait at the pool size, which a
  # coin flip among equals would not — and among seen entries the oldest date
  # wins. Per user, because the concern is one reader's recognition replacing
  # reasoning. Nil when the pool is empty or nothing in it resolves.
  def self.pick(mode, last_seen:)
    candidates  = pool(mode).select { |excerpt| usable?(excerpt) }
    never, seen = candidates.partition { |excerpt| !last_seen.key?(excerpt.id) }

    never.first || seen.min_by { |excerpt| [ last_seen.fetch(excerpt.id), candidates.index(excerpt) ] }
  end

  # `{ id => last date }` over this user's exercises, read back from the
  # trace ProblemSetIngest stamps into problem_set. code_review_mode itself is
  # never persisted, so this trace is the only record of what was grounded.
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
