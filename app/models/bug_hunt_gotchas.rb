# Design notes: docs/code-notes/app/models/bug_hunt_gotchas.md
module BugHuntGotchas
  Entry = Data.define(:id, :language, :concept, :rule)

  def self.entry(language, id, concept, rule) = Entry.new(id: id, language: language, concept: concept, rule: rule)
  private_class_method :entry

  # Appended, never inserted: list order is the never-seen drain order.
  RUBY = [
    entry("ruby_rails", "rb_delete_while_each", "array_mutation_pitfalls",
          "Delete from an array inside its own `each` loop, so the element after each removal is skipped."),
    entry("ruby_rails", "rb_shared_hash_default", "array_mutation_pitfalls",
          "Build a grouping with `Hash.new([])` and `<<`, so every key shares the one default array and no key is ever stored."),
    entry("ruby_rails", "rb_array_new_shared_row", "array_mutation_pitfalls",
          "Build a grid with `Array.new(n, [])`, so every row is the same array and a change to one row shows in all of them."),
    entry("ruby_rails", "rb_bang_returns_nil", "array_mutation_pitfalls",
          "Chain a call onto `uniq!`, `compact!` or `strip!`, which return nil when they change nothing."),
    entry("ruby_rails", "rb_memo_falsy", "memoization",
          "Memoize a true-or-false result with `||=`, so a false result is recomputed on every call."),
    entry("ruby_rails", "rb_memo_partial_key", "cache_key_completeness",
          "Memoize into a hash keyed on one of a method's two arguments, so a call with a different second argument gets the first call's result."),
    entry("ruby_rails", "rb_integer_division", "allocation_rounding",
          "Compute a percentage as `part / whole * 100` on Integers, so integer division truncates before the multiply."),
    entry("ruby_rails", "rb_split_remainder", "allocation_rounding",
          "Split an Integer total of cents evenly with `/`, so the remainder cents are lost."),
    entry("ruby_rails", "rb_float_equality", "allocation_rounding",
          "Compare sums of decimal Float amounts with `==`, which fails for values binary floats can't hold exactly."),
    entry("ruby_rails", "rb_to_i_silent", "semantic_input_validation",
          "Turn text input into a number with `to_i`, which never fails, so invalid text passes as 0 or as its leading digits."),
    entry("ruby_rails", "rb_ensure_return", "error_handling",
          "Put a `return` inside an `ensure` block, which discards the exception being raised.")
  ].freeze

  JAVASCRIPT = [
    entry("javascript", "js_splice_while_looping", "array_mutation_pitfalls",
          "Remove items with `splice(i, 1)` inside an index `for` loop, so the item after each removal is skipped."),
    entry("javascript", "js_sort_mutates", "array_mutation_pitfalls",
          "Take a sorted copy with `items.sort(...)` and later read `items` as if it kept its original order."),
    entry("javascript", "js_fill_shared", "array_mutation_pitfalls",
          "Build a grid with `new Array(n).fill([])`, so every row is the same array and a push to one row shows in all of them."),
    entry("javascript", "js_default_sort", "deterministic_ordering",
          "Sort numbers with `sort()` and no comparator, which compares them as strings."),
    entry("javascript", "js_integer_keys_reorder", "deterministic_ordering",
          "Rely on `Object.keys` insertion order for an object keyed by integer-like ids, which are listed first in numeric order."),
    entry("javascript", "js_var_in_loop", "closures_in_loops",
          "Create callbacks inside a `for (var i ...)` loop, so every callback sees the loop's final `i`."),
    entry("javascript", "js_detached_method", "this_binding",
          "Take a `class` method off its instance into a variable and call it, so `this` is undefined and the call throws."),
    entry("javascript", "js_arrow_method", "this_binding",
          "Write an exported object literal's method as an arrow function that uses `this`, which is the module's undefined top-level `this`."),
    entry("javascript", "js_foreach_async", "promise_chaining",
          "Run async saves with `forEach(async ...)` in an `async` function that then returns a copy of what was saved (`return [...saved]`), " \
          "so the copy is made before any save finishes; never return the live array."),
    entry("javascript", "js_then_no_return", "promise_chaining",
          "Chain `.then` steps on a plain `Promise.resolve` helper where one step has a block body with no `return`, " \
          "so the next step receives undefined."),
    entry("javascript", "js_map_parseint", "semantic_input_validation",
          "Convert strings with `map(parseInt)`, so each index is passed as `parseInt`'s radix."),
    entry("javascript", "js_object_key_coercion", "cache_key_completeness",
          "Cache results in a plain object keyed by an object argument, which becomes the string \"[object Object]\" for every key.")
  ].freeze

  BY_LANGUAGE = { "ruby_rails" => RUBY, "javascript" => JAVASCRIPT }.freeze

  def self.all = BY_LANGUAGE.values.flatten

  def self.for_language(language)
    BY_LANGUAGE.fetch(language) { raise ConceptVocabulary::UnknownLanguage, "No bug hunt registry for #{language.inspect}" }
  end

  def self.concepts(language) = for_language(language).map(&:concept).uniq

  def self.find(id) = all.find { |entry| entry.id == id }

  def self.pick(language, last_seen:, featured: nil)
    bucket      = ConceptBucket.for(ExerciseSection::CodeReview.key, language)
    entries     = for_language(language).reject { |entry| featured&.marks?(concept: entry.concept, bucket: bucket) }
    never, seen = entries.partition { |entry| !last_seen.key?(entry.id) }

    never.first || seen.min_by { |entry| [ last_seen.fetch(entry.id), entries.index(entry) ] }
  end

  def self.last_seen_for(user)
    user.daily_exercises
        .where("plan_notes ->> 'bug_hunt' IS NOT NULL")
        .where("problem_set -> 'code_review' ->> ? IS NOT NULL", ExerciseSection::CodeReview::BugHunt::PURPOSE_FIELD)
        .group("plan_notes ->> 'bug_hunt'")
        .maximum(:date)
  end
end
