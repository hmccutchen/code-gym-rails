# Per-Kind Rotation Weight Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an engineer bias how often each rotating section kind appears, with a separate action to remove a kind from rotation entirely, layered on top of the existing staleness rotation without weakening its starvation guarantee.

**Architecture:** A user's stated bias becomes a multiplier applied at exactly one place — the weighted-roll branch of `SectionRotation.pick_kind` — so `effective_weight = staleness × user_multiplier`. The starvation branch runs first and never reads a multiplier, which makes "a low weight cannot starve a kind" structurally true. Exclusion is a separate action that removes a kind from the pool before the starvation check and everywhere else the pool is read. Preferences travel as a pure `KindPreferences` value object, never a `User`, keeping `SectionRotation`'s specs free of the database.

**Tech Stack:** Rails 8.0 / PostgreSQL (jsonb), RSpec, Capybara + capybara-playwright-driver for the one system spec. No new gems. Inline `<script>` only — this app loads no Turbo/Stimulus.

**Spec:** `docs/superpowers/specs/2026-09-14-section-kind-weight-preferences-design.md`

## Global Constraints

- Branch `feature/section-kind-weight-preferences` is already checked out. Never commit to `main`.
- `effective_weight = staleness × user_multiplier`. No base-weight term — `SectionRotation` deliberately has none today.
- The starvation branch must never read a multiplier. It returns before weights are built.
- Weights never affect slot choice. Exclusions do affect slot choice, because `slot_staleness` is a `max` over the pool.
- Stops are exactly `[0.25, 0.5, 1.0, 2.0, 4.0]`, default `1.0`. Storage is sparse: a kind at ×1 stores no key.
- Never read or expose `ConceptMastery` tier state anywhere in this feature.
- No change to `code_review` content modes, the `RealSource` sub-roll, `ConceptMastery`, retention scheduling, or `SectionCount`.
- Section labels in views come from `t("sections.#{key}.name")`, never a humanized key.
- Style baseline is `rubocop-rails-omakase`. `Metrics` and `Naming` cops are off; new methods stay under 25 lines. `Lint/UselessAssignment` is off — grep for dead locals after any extraction.
- Comments explain a non-obvious *why* only. Never restate what the code does.
- Run specs without piping through `tail` — a piped exit code hides a red suite.

---

### Task 1: `ExerciseSection.rotatable`

The registry answers which kinds get a control. Derived from slot shape so a ninth kind needs no edit here.

**Files:**
- Modify: `app/models/exercise_section.rb` (add after `.slot_count`, around line 67)
- Test: `spec/models/exercise_section_spec.rb`

**Interfaces:**
- Consumes: `ExerciseSection.slots` (existing).
- Produces: `ExerciseSection.rotatable` → `Array<Class>`, the four thirds plus three fourths, in slot order. Used by Task 5 (validations) and Task 8 (view).

- [ ] **Step 1: Write the failing test**

Append inside the existing top-level `RSpec.describe ExerciseSection do` block in `spec/models/exercise_section_spec.rb` (create the file with `require "rails_helper"` and the describe block if it does not exist):

```ruby
  describe ".rotatable" do
    it "holds every kind that competes for a slot" do
      expect(described_class.rotatable).to match_array(described_class.thirds + described_class.fourths)
    end

    it "omits the kinds whose slot offers no choice" do
      expect(described_class.rotatable)
        .not_to include(ExerciseSection::CodeReview, ExerciseSection::Pattern)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/exercise_section_spec.rb -e "rotatable"`
Expected: FAIL with `NoMethodError: undefined method 'rotatable' for ExerciseSection`

- [ ] **Step 3: Write minimal implementation**

In `app/models/exercise_section.rb`, immediately after `self.slot_count`:

```ruby
  # Which kinds a user can bias or exclude. A slot holding one candidate has no
  # choice to bias — its roll returns that kind at any weight — so a control
  # there would be one that provably does nothing.
  def self.rotatable
    slots.values.select { |kinds| kinds.size > 1 }.flatten
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/exercise_section_spec.rb -e "rotatable"`
Expected: PASS (2 examples)

- [ ] **Step 5: Commit**

```bash
git add app/models/exercise_section.rb spec/models/exercise_section_spec.rb
git commit -m "Add ExerciseSection.rotatable, derived from slot shape"
```

---

### Task 2: Migration — two jsonb columns on `users`

**🚩 This is the only migration in the plan.** Additive, defaulted, no backfill, no index.

**Files:**
- Create: `db/migrate/20260914000001_add_section_kind_preferences_to_users.rb`
- Modify: `db/schema.rb` (generated by running the migration — do not hand-edit)
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Produces: `User#section_kind_weights` → `Hash` (default `{}`), `User#excluded_section_kinds` → `Array` (default `[]`). Read by Task 3's `KindPreferences.for`, validated in Task 5, written in Task 7.

- [ ] **Step 1: Write the failing test**

Append to `spec/models/user_spec.rb` inside the top-level describe block:

```ruby
  describe "section kind preferences" do
    it "starts with no stated preference at all" do
      user = create_user_with_key

      expect(user.section_kind_weights).to eq({})
      expect(user.excluded_section_kinds).to eq([])
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/user_spec.rb -e "no stated preference"`
Expected: FAIL with `NoMethodError: undefined method 'section_kind_weights'`

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260914000001_add_section_kind_preferences_to_users.rb`:

```ruby
class AddSectionKindPreferencesToUsers < ActiveRecord::Migration[8.0]
  # Two columns rather than one nested blob: a low weight and an exclusion are
  # different actions, and storing them as two fields of one fact is the
  # conflation the UI copy exists to prevent, reintroduced underneath it.
  def change
    add_column :users, :section_kind_weights,   :jsonb, default: {}, null: false
    add_column :users, :excluded_section_kinds, :jsonb, default: [], null: false
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `bundle exec rails db:migrate`
Expected: both `add_column` lines echoed; `db/schema.rb` version becomes `2026_09_14_000001` and gains both columns on `users`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/models/user_spec.rb -e "no stated preference"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260914000001_add_section_kind_preferences_to_users.rb db/schema.rb spec/models/user_spec.rb
git commit -m "Add section_kind_weights and excluded_section_kinds to users"
```

---

### Task 3: `KindPreferences` value object

Pure, no database — this is what keeps `SectionRotation`'s specs DB-free, the way `SectionCount.for(history, adaptive:)` already does.

**Files:**
- Create: `app/models/kind_preferences.rb`
- Test: `spec/models/kind_preferences_spec.rb`

**Interfaces:**
- Consumes: `ExerciseSection` kind classes (their `.key` → `String`), `User#section_kind_weights` / `#excluded_section_kinds` from Task 2.
- Produces:
  - `KindPreferences::MULTIPLIERS` → `[0.25, 0.5, 1.0, 2.0, 4.0]` (frozen)
  - `KindPreferences::DEFAULT_MULTIPLIER` → `1.0`
  - `KindPreferences.none` → instance with no stated preference
  - `KindPreferences.for(user)` → instance
  - `KindPreferences.new(weights:, excluded:)` → instance
  - `#multiplier_for(kind)` → `Float`
  - `#excluded?(kind)` → `true`/`false`

  Used by Tasks 4 (rotation), 5 (validation constant), 6 (DailyPlan), 7 (controller constant), 8 (view constant).

- [ ] **Step 1: Write the failing test**

Create `spec/models/kind_preferences_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe KindPreferences do
  # A stand-in rather than a record: this object is deliberately built from
  # plain values, and a spec that needed the database would hide that.
  def stated(weights: {}, excluded: [])
    Struct.new(:section_kind_weights, :excluded_section_kinds).new(weights, excluded)
  end

  let(:challenge) { ExerciseSection::Challenge }
  let(:parsons)   { ExerciseSection::ParsonsProblem }

  describe "#multiplier_for" do
    it "defaults a kind the user has not touched" do
      expect(described_class.none.multiplier_for(challenge)).to eq(1.0)
    end

    it "returns a stated stop" do
      preferences = described_class.new(weights: { "challenge" => 4.0 }, excluded: [])

      expect(preferences.multiplier_for(challenge)).to eq(4.0)
    end

    it "leaves other kinds at the default" do
      preferences = described_class.new(weights: { "challenge" => 4.0 }, excluded: [])

      expect(preferences.multiplier_for(parsons)).to eq(1.0)
    end

    # Totality matters more than strictness here: a zero would make a kind
    # unpickable below starvation, which is the failure mode this whole feature
    # is built to avoid, and a negative would corrupt every other kind's share
    # of the roll.
    it "falls back to the default for a value outside the stops" do
      [ 0, -1, 3.0, "0.5", nil ].each do |junk|
        preferences = described_class.new(weights: { "challenge" => junk }, excluded: [])

        expect(preferences.multiplier_for(challenge)).to eq(1.0)
      end
    end
  end

  describe "#excluded?" do
    it "is true only for a kind the user excluded" do
      preferences = described_class.new(weights: {}, excluded: [ "challenge" ])

      expect(preferences.excluded?(challenge)).to be(true)
      expect(preferences.excluded?(parsons)).to be(false)
    end

    it "is false for everything when nothing is stated" do
      expect(ExerciseSection.rotatable).to all(satisfy { |kind| !described_class.none.excluded?(kind) })
    end
  end

  describe ".for" do
    it "treats a user who has stated nothing as no preferences at all" do
      preferences = described_class.for(stated)

      ExerciseSection.rotatable.each do |kind|
        expect(preferences.multiplier_for(kind)).to eq(described_class::DEFAULT_MULTIPLIER)
        expect(preferences.excluded?(kind)).to be(false)
      end
    end

    it "reads both stated columns" do
      preferences = described_class.for(stated(weights: { "challenge" => 0.25 }, excluded: [ "parsons_problem" ]))

      expect(preferences.multiplier_for(challenge)).to eq(0.25)
      expect(preferences.excluded?(parsons)).to be(true)
    end
  end

  # The signature is the guarantee that a curation preference can never become a
  # readout of mastery: this object is handed stated preference and nothing
  # else, so tier state is not merely unused here — it is unreachable.
  it "is constructed from stated preference alone" do
    expect(described_class.instance_method(:initialize).parameters)
      .to eq([ [ :keyreq, :weights ], [ :keyreq, :excluded ] ])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/kind_preferences_spec.rb`
Expected: FAIL with `NameError: uninitialized constant KindPreferences`

- [ ] **Step 3: Write the implementation**

Create `app/models/kind_preferences.rb`:

```ruby
# A user's stated bias over which rotating kinds they see, as plain values.
# SectionRotation takes one of these rather than a User — the same shape
# SectionCount's `adaptive:` uses — so the rotation's specs need no database.
#
# Total by construction: a stored value outside MULTIPLIERS reads as the
# default rather than reaching WeightedRoll, where a zero would make a kind
# unpickable below starvation and a negative would corrupt every other kind's
# share of the roll.
class KindPreferences
  MULTIPLIERS        = [ 0.25, 0.5, 1.0, 2.0, 4.0 ].freeze
  DEFAULT_MULTIPLIER = 1.0

  def self.none
    new(weights: {}, excluded: [])
  end

  def self.for(user)
    new(weights: user.section_kind_weights, excluded: user.excluded_section_kinds)
  end

  def initialize(weights:, excluded:)
    @weights  = weights
    @excluded = excluded
  end

  def multiplier_for(kind)
    value = @weights[kind.key]

    MULTIPLIERS.include?(value) ? value : DEFAULT_MULTIPLIER
  end

  def excluded?(kind)
    @excluded.include?(kind.key)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/kind_preferences_spec.rb`
Expected: PASS (9 examples, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/models/kind_preferences.rb spec/models/kind_preferences_spec.rb
git commit -m "Add KindPreferences, a pure value object for stated rotation bias"
```

---

### Task 4: Compose the multiplier into `SectionRotation`

The core of the feature. Three invariants land here.

**Files:**
- Modify: `app/services/section_rotation.rb` (`.for`, `.eligible`, `.slot_staleness`, `.pick_kind`)
- Test: `spec/services/section_rotation_spec.rb`

**Interfaces:**
- Consumes: `KindPreferences` (Task 3), `ExerciseHistoryEntry = Data.define(:section_keys, :answered)`, `WeightedRoll.pick(weights)`.
- Produces: `SectionRotation.for(history, count:, preferences: KindPreferences.none)` → `{ pattern:, third:, fourth: }` with `Symbol` or `nil` values. Consumed by Task 6.

- [ ] **Step 1: Write the failing tests**

Append to `spec/services/section_rotation_spec.rb`, inside the existing `RSpec.describe SectionRotation do` block. The file already defines `history(*key_sets)` at the top — reuse it.

```ruby
  def preferences(weights: {}, excluded: [])
    KindPreferences.new(weights: weights, excluded: excluded)
  end

  # Every third kind seen in the newest entry, so all four sit at staleness 1
  # and nothing is starved. Equal staleness is what leaves the multiplier as the
  # only thing separating them.
  def all_thirds_fresh
    history(%w[code_review architecture security_review challenge parsons_problem])
  end

  describe "user weights" do
    # Equal staleness gives four equal weights, so the roll's boundaries sit at
    # .25/.50/.75. Weighting challenge x4 makes the total 7 and moves its band to
    # .2857...8571 — so the SAME roll that used to land on security_review now
    # lands on challenge. Asserting both at one rand value pins the arithmetic,
    # not merely the direction.
    it "shifts the roll's boundaries by the stated multiplier" do
      allow(WeightedRoll).to receive(:rand).and_return(0.30)

      unweighted = described_class.send(:pick_kind, :third, all_thirds_fresh, KindPreferences.none)
      weighted   = described_class.send(:pick_kind, :third, all_thirds_fresh,
                                        preferences(weights: { "challenge" => 4.0 }))

      expect(unweighted).to eq(:security_review)
      expect(weighted).to eq(:challenge)
    end

    it "lands past a weighted kind's band on a high roll" do
      allow(WeightedRoll).to receive(:rand).and_return(0.90)

      chosen = described_class.send(:pick_kind, :third, all_thirds_fresh,
                                    preferences(weights: { "challenge" => 4.0 }))

      expect(chosen).to eq(:parsons_problem)
    end

    # The guarantee the whole feature is built around. Stubbing the roll to
    # raise proves the starvation branch returned before any weight was read —
    # structural, where asserting "it still shows up sometimes" would only be
    # statistical.
    it "cannot starve a kind, however low its weight" do
      recent = history(*Array.new(12, %w[code_review pattern architecture security_review parsons_problem]))
      allow(WeightedRoll).to receive(:pick).and_raise("the weighted roll must not be reached")

      chosen = described_class.send(:pick_kind, :third, recent,
                                    preferences(weights: { "challenge" => 0.25 }))

      expect(chosen).to eq(:challenge)
    end

    it "leaves slot filling untouched" do
      recent = history(*Array.new(12, %w[code_review pattern plan_review]))
      damped = preferences(weights: ExerciseSection.thirds.to_h { |kind| [ kind.key, 0.25 ] })

      filled = ->(prefs) { described_class.for(recent, count: 2, preferences: prefs).transform_values(&:present?) }

      expect(filled.call(damped)).to eq(filled.call(KindPreferences.none))
    end

    it "does not leak across the third and fourth tracks" do
      allow(WeightedRoll).to receive(:rand).and_return(0.30)
      recent = all_thirds_fresh

      with    = described_class.for(recent, count: 4, preferences: preferences(weights: { "plan_review" => 4.0 }))
      without = described_class.for(recent, count: 4, preferences: KindPreferences.none)

      expect(with[:third]).to eq(without[:third])
    end

    it "matches the unweighted rotation when nothing is stated" do
      allow(WeightedRoll).to receive(:rand).and_return(0.42)
      recent = all_thirds_fresh

      [ 2, 3, 4 ].each do |count|
        expect(described_class.for(recent, count: count, preferences: KindPreferences.none))
          .to eq(described_class.for(recent, count: count))
      end
    end
  end

  describe "excluded kinds" do
    # Exclusion is applied before the starvation check, which is the whole
    # difference between it and a low weight: a starved kind is taken outright,
    # so anything that could not remove a kind from the pool entirely would be
    # overridden here.
    it "keeps an excluded kind out even when it is starved" do
      recent = history(*Array.new(12, %w[code_review pattern architecture security_review parsons_problem]))

      chosen = described_class.send(:pick_kind, :third, recent, preferences(excluded: [ "challenge" ]))

      expect(chosen).not_to eq(:challenge)
    end

    # slot_staleness is a max over the pool, so an excluded kind left in it would
    # pull its slot into a scarce spot on the strength of a kind that can never
    # fill it. Here architecture is the only stale third; excluding it hands the
    # slot to the fourth track.
    it "stops an excluded kind pulling its slot into a short day" do
      recent = history(*Array.new(12, %w[code_review pattern challenge security_review parsons_problem plan_review]))

      expect(described_class.for(recent, count: 2)[:third]).to be_present

      excluded = described_class.for(recent, count: 2, preferences: preferences(excluded: [ "architecture" ]))

      expect(excluded[:third]).to be_nil
      expect(excluded[:fourth]).to be_present
    end

    # User validation refuses this, so it can only arrive from a hand-edited
    # row. A slot with an empty pool would break slot ranking outright, and a
    # day that silently loses a section is worse than one ignoring an impossible
    # preference.
    it "ignores an exclusion that would empty a slot" do
      excluded = ExerciseSection.thirds.map(&:key)

      chosen = described_class.send(:pick_kind, :third, all_thirds_fresh, preferences(excluded: excluded))

      expect(ExerciseSection.thirds.map { |kind| kind.key.to_sym }).to include(chosen)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/section_rotation_spec.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :preferences` and `ArgumentError: wrong number of arguments` from the `pick_kind` calls.

- [ ] **Step 3: Write the implementation**

In `app/services/section_rotation.rb`, replace `.for`, `.eligible`, `.slot_staleness` and `.pick_kind` with:

```ruby
  def self.for(history, count:, preferences: KindPreferences.none)
    recent    = history.first(LOOKBACK)
    available = (count - MANDATORY_SLOT_COUNT).clamp(0, OPTIONAL_SLOTS.size)

    filled = OPTIONAL_SLOTS
      .sort_by { |slot| [ -slot_staleness(slot, recent, preferences), OPTIONAL_SLOTS.index(slot) ] }
      .first(available)

    OPTIONAL_SLOTS.index_with { |slot| filled.include?(slot) ? pick_kind(slot, recent, preferences) : nil }
  end

  # Exclusion removes a kind from the pool everywhere the pool is read — the
  # roll, the starvation check, and the slot's own staleness. A weight never
  # does; it only leans the roll. That asymmetry is the point: a slot ranked on
  # a kind that can never fill it would win a scarce spot on false strength.
  #
  # User validation refuses an exclusion that would empty a slot, so the
  # fallback below is for a row that got past it. Ignoring an impossible
  # preference beats a day that silently drops a section.
  def self.eligible(slot, preferences)
    kinds = ExerciseSection.slots.fetch(slot)

    kinds.reject { |kind| preferences.excluded?(kind) }.presence || kinds
  end
  private_class_method :eligible

  def self.slot_staleness(slot, recent, preferences)
    eligible(slot, preferences).map { |kind| staleness(kind, recent) }.max
  end
  private_class_method :slot_staleness

  # A starved kind is taken outright rather than rolled for, and ties among
  # equally stale starved kinds drain in registry order: scheduling one resets
  # its staleness, so a fixed order empties the pool one per day and bounds the
  # worst-case wait at the pool size, which a coin flip among equals would not.
  # Below starvation, equally stale kinds get equal weight and the tie breaks
  # randomly — see the weighted-roll comment below.
  #
  # The user's multiplier reaches the roll and nothing else. Starvation returns
  # above it, so no weight can hold a kind out of rotation indefinitely — the
  # failure mode staleness-weighting replaced.
  def self.pick_kind(slot, recent, preferences)
    kinds   = eligible(slot, preferences)
    starved = kinds.select { |kind| staleness(kind, recent) > STARVATION_LIMIT }

    return most_stale(starved, recent).key.to_sym if starved.any?

    # Weighted by staleness times the user's stated bias — no base-weights table
    # multiplied in. No kind here is the baseline the others vary from, so
    # recency and stated preference are the only things separating them
    # (DailyPlan's old fixed third/fourth weight tables were uniform for the
    # same reason, before this replaced them).
    weights = kinds.index_with { |kind| staleness(kind, recent) * preferences.multiplier_for(kind) }
    WeightedRoll.pick(weights).key.to_sym
  end
  private_class_method :pick_kind
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/section_rotation_spec.rb`
Expected: PASS — the 6 pre-existing examples plus 9 new ones, 0 failures. If a pre-existing example fails, the default kwarg is not behaving as `KindPreferences.none`; fix that rather than editing the old example.

- [ ] **Step 5: Check for dead locals and run the wider suite**

Run: `grep -n "kinds\|recent\|preferences" app/services/section_rotation.rb`
Expected: no assigned-but-unused locals (`Lint/UselessAssignment` is disabled in this repo, so this is manual).

Run: `bundle exec rspec spec/services spec/models --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add app/services/section_rotation.rb spec/services/section_rotation_spec.rb
git commit -m "Multiply stated user bias into the rotation's weighted roll only"
```

---

### Task 5: `User` validations

The boundary that refuses an unknown kind, an off-stop value, and an exclusion that would empty a slot.

**Files:**
- Modify: `app/models/user.rb` (validations near line 22; private methods after line 428's `private`)
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Consumes: `ExerciseSection.rotatable` (Task 1), `KindPreferences::MULTIPLIERS` (Task 3).
- Produces: a `User` that rejects invalid preference payloads, relied on by Task 7's controller.

- [ ] **Step 1: Write the failing tests**

Append to `spec/models/user_spec.rb`, inside the `describe "section kind preferences"` block added in Task 2:

```ruby
    it "accepts a stated stop for a rotatable kind" do
      user = create_user_with_key
      user.section_kind_weights = { "challenge" => 0.25 }

      expect(user).to be_valid
    end

    it "rejects a weight for a kind that does not compete for a slot" do
      user = create_user_with_key
      user.section_kind_weights = { "code_review" => 0.5 }

      expect(user).not_to be_valid
      expect(user.errors[:section_kind_weights]).to be_present
    end

    it "rejects a weight that is not one of the stops" do
      user = create_user_with_key
      user.section_kind_weights = { "challenge" => 3.0 }

      expect(user).not_to be_valid
      expect(user.errors[:section_kind_weights]).to be_present
    end

    it "rejects an exclusion naming an unknown kind" do
      user = create_user_with_key
      user.excluded_section_kinds = [ "nonsense" ]

      expect(user).not_to be_valid
      expect(user.errors[:excluded_section_kinds]).to be_present
    end

    it "allows excluding all but one kind in a slot" do
      user = create_user_with_key
      user.excluded_section_kinds = ExerciseSection.thirds.drop(1).map(&:key)

      expect(user).to be_valid
    end

    # Excluding is per-kind curation, never a way to delete a whole slot: an
    # empty slot would render fewer sections than SectionCount asked for, which
    # lowers the completion mean, which shrinks the set again.
    it "refuses an exclusion that would empty a slot" do
      user = create_user_with_key
      user.excluded_section_kinds = ExerciseSection.thirds.map(&:key)

      expect(user).not_to be_valid
      expect(user.errors[:excluded_section_kinds].join).to include("third")
    end

    it "refuses an exclusion that would empty the fourth slot" do
      user = create_user_with_key
      user.excluded_section_kinds = ExerciseSection.fourths.map(&:key)

      expect(user).not_to be_valid
      expect(user.errors[:excluded_section_kinds].join).to include("fourth")
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/user_spec.rb -e "section kind preferences"`
Expected: FAIL — the rejection examples fail because the record is still valid.

- [ ] **Step 3: Write the implementation**

In `app/models/user.rb`, after `validate :time_zone_must_be_loadable` (line 22):

```ruby
  validate :section_kind_weights_name_rotatable_kinds
  validate :excluded_section_kinds_name_rotatable_kinds
  validate :every_slot_keeps_a_kind
```

Then, under the existing `private` on line 428, add:

```ruby
  def rotatable_keys
    ExerciseSection.rotatable.map(&:key)
  end

  def section_kind_weights_name_rotatable_kinds
    return errors.add(:section_kind_weights, "must be an object") unless section_kind_weights.is_a?(Hash)

    section_kind_weights.each do |key, value|
      errors.add(:section_kind_weights, "names an unknown section kind: #{key}") if rotatable_keys.exclude?(key)
      errors.add(:section_kind_weights, "has an unsupported weight for #{key}") if KindPreferences::MULTIPLIERS.exclude?(value)
    end
  end

  def excluded_section_kinds_name_rotatable_kinds
    return errors.add(:excluded_section_kinds, "must be a list") unless excluded_section_kinds.is_a?(Array)

    (excluded_section_kinds - rotatable_keys).each do |key|
      errors.add(:excluded_section_kinds, "names an unknown section kind: #{key}")
    end
  end

  # Derived from the slot roster rather than naming third and fourth, so a
  # future multi-kind slot is covered without an edit here.
  def every_slot_keeps_a_kind
    return unless excluded_section_kinds.is_a?(Array)

    ExerciseSection.slots.each do |slot, kinds|
      next if kinds.size <= 1
      next if kinds.any? { |kind| excluded_section_kinds.exclude?(kind.key) }

      errors.add(:excluded_section_kinds, "must leave at least one #{slot} section in rotation")
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: PASS — the 7 new examples plus every pre-existing one.

- [ ] **Step 5: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "Validate stated rotation preferences against the registry"
```

---

### Task 6: Wire preferences through `DailyPlan`

**Files:**
- Modify: `app/services/daily_plan.rb` (the `rotation` assignment inside `.for`, around line 84)
- Test: `spec/services/daily_plan_spec.rb`

**Interfaces:**
- Consumes: `KindPreferences.for(user)` (Task 3), `SectionRotation.for(history, count:, preferences:)` (Task 4).
- Produces: no new public interface — `DailyPlan::Result` is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `spec/services/daily_plan_spec.rb` inside the top-level describe block:

```ruby
  describe "stated rotation preferences" do
    it "hands the user's stated preferences to the rotation" do
      user = create_fake_provider_user
      user.update!(excluded_section_kinds: [ "parsons_problem" ])

      allow(SectionRotation).to receive(:for).and_call_original

      described_class.for(user, language: "ruby_rails")

      expect(SectionRotation).to have_received(:for) do |_history, count:, preferences:|
        expect(count).to be_a(Integer)
        expect(preferences.excluded?(ExerciseSection::ParsonsProblem)).to be(true)
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/daily_plan_spec.rb -e "stated rotation preferences"`
Expected: FAIL with `ArgumentError: missing keyword: :preferences` inside the `have_received` block (the real call passes no `preferences:`).

- [ ] **Step 3: Write the implementation**

In `app/services/daily_plan.rb`, replace the `rotation` line inside `.for`:

```ruby
    rotation      = SectionRotation.for(history,
                                        count: SectionCount.for(history, adaptive: user.adaptive_set_size?),
                                        preferences: KindPreferences.for(user))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/daily_plan_spec.rb`
Expected: PASS, including every pre-existing example.

- [ ] **Step 5: Commit**

```bash
git add app/services/daily_plan.rb spec/services/daily_plan_spec.rb
git commit -m "Read the user's stated rotation preferences in DailyPlan"
```

---

### Task 7: `ProfileController` boundary

Strict at the boundary, following the `BOOLEAN_VALUES` precedent already in this file.

**Files:**
- Modify: `app/controllers/profile_controller.rb`
- Test: `spec/requests/profile_spec.rb`

**Interfaces:**
- Consumes: `KindPreferences::MULTIPLIERS` (Task 3), `User` validations (Task 5).
- Produces: `PATCH /profile` accepting `user[section_kind_weights]` (object of kind-key → number) and `user[excluded_section_kinds]` (array of kind keys).

**Note:** do **not** add the new fields to the rendered JSON. `spec/requests/profile_spec.rb` asserts the response body with `eq(...)` on an exact hash, and widening it would mean editing a passing assertion. The script does not read the echo.

- [ ] **Step 1: Write the failing tests**

Append to `spec/requests/profile_spec.rb` inside `describe "PATCH /profile"`:

```ruby
    def patch_profile(payload)
      patch profile_path,
            params: { user: payload }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    it "stores stated weights and exclusions" do
      login_as(user)

      patch_profile(section_kind_weights: { "challenge" => 0.25 }, excluded_section_kinds: [ "parsons_problem" ])

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_weights).to eq("challenge" => 0.25)
      expect(user.excluded_section_kinds).to eq([ "parsons_problem" ])
    end

    # Active Record's cast is too forgiving for a request boundary — the same
    # reasoning as BOOLEAN_VALUES above it.
    it "rejects a weight sent as a string" do
      login_as(user)

      patch_profile(section_kind_weights: { "challenge" => "0.25" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.section_kind_weights).to eq({})
    end

    it "rejects a weight that is not one of the stops" do
      login_as(user)

      patch_profile(section_kind_weights: { "challenge" => 3 })

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.section_kind_weights).to eq({})
    end

    it "refuses an exclusion that would empty a slot" do
      login_as(user)

      patch_profile(excluded_section_kinds: ExerciseSection.thirds.map(&:key))

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.excluded_section_kinds).to eq([])
    end

    # Writes replace rather than merge, so returning a slider to its default is
    # expressed by the key being absent — one representation of default, not two.
    it "replaces the stored preferences rather than merging into them" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 0.25, "architecture" => 2.0 })

      patch_profile(section_kind_weights: { "architecture" => 2.0 })

      expect(response).to have_http_status(:ok)
      expect(user.reload.section_kind_weights).to eq("architecture" => 2.0)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/requests/profile_spec.rb`
Expected: FAIL — the write examples leave `{}` because the params are not permitted; the string example returns 200 rather than 422.

- [ ] **Step 3: Write the implementation**

In `app/controllers/profile_controller.rb`, change `#update`'s guard clause and add the new private methods:

```ruby
  def update
    return render_invalid_boolean if invalid_adaptive_set_size?
    return render_invalid_weight  if invalid_section_kind_weights?
```

Then, in the private section:

```ruby
  # A weight arrives from a range input indexing a server-rendered list, so a
  # non-numeric or off-stop value means a malformed request rather than a user
  # action. Rejected here for the same reason as BOOLEAN_VALUES above: the
  # column's cast would quietly turn "0.25" into 0.0.
  def invalid_section_kind_weights?
    weights = params.require(:user)[:section_kind_weights]
    return false if weights.blank?
    return true  unless weights.respond_to?(:to_unsafe_h)

    weights.to_unsafe_h.values.any? { |value| !value.is_a?(Numeric) || KindPreferences::MULTIPLIERS.exclude?(value.to_f) }
  end

  def render_invalid_weight
    render json: { errors: [ "Section weight must be one of #{KindPreferences::MULTIPLIERS.join(', ')}" ] },
           status: :unprocessable_content
  end
```

And extend `profile_params`:

```ruby
  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :adaptive_set_size,
                                             section_kind_weights: {}, excluded_section_kinds: [])
    permitted[:name] = permitted[:name].to_s.strip if permitted.key?(:name)
    permitted[:time_zone] = permitted[:time_zone].to_s.strip.presence if permitted.key?(:time_zone)
    # permit(x: {}) yields Parameters, which a jsonb column cannot serialize.
    permitted[:section_kind_weights] = permitted[:section_kind_weights].to_h if permitted.key?(:section_kind_weights)
    permitted
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/requests/profile_spec.rb`
Expected: PASS — 5 new examples plus every pre-existing one, including the exact-body assertion, which must remain untouched.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/profile_controller.rb spec/requests/profile_spec.rb
git commit -m "Accept stated rotation preferences at the profile boundary"
```

---

### Task 8: The `/setup` control

**Files:**
- Modify: `config/locales/en.yml` (new top-level `exercise_mix:` block, alongside `sections:`)
- Modify: `app/views/api_keys/edit.html.erb`
- Test: `spec/requests/api_keys_spec.rb`

**Interfaces:**
- Consumes: `ExerciseSection.rotatable`, `ExerciseSection.slots`, `KindPreferences::MULTIPLIERS`, `current_user.section_kind_weights`, `current_user.excluded_section_kinds`, `t("sections.#{key}.name")`, `profile_path`.
- Produces: DOM contract used by Task 9 — `#exercise-mix` (the `<details>`), `input[type=range]#weight-<key>`, `input[type=checkbox]#exclude-<key>`, `output#weight-label-<key>`, and `data-slot="<slot>"` on each row.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/api_keys_spec.rb` inside the `GET /setup` describe block:

```ruby
    it "renders a weight control and an exclude toggle for every rotatable kind" do
      login_as(user)

      get setup_path

      ExerciseSection.rotatable.each do |kind|
        expect(response.body).to include(%(id="weight-#{kind.key}"))
        expect(response.body).to include(%(id="exclude-#{kind.key}"))
        expect(response.body).to include(I18n.t("sections.#{kind.key}.name"))
      end
    end

    it "renders the stops from the constant rather than restating them" do
      login_as(user)

      get setup_path

      expect(response.body).to include(KindPreferences::MULTIPLIERS.to_json)
    end

    # The copy is load-bearing: the two controls mean different things, and a
    # slider at its minimum provably cannot mean "never" while the starvation
    # guarantee stands.
    it "says excluding is a different action from a low weight" do
      login_as(user)

      get setup_path

      expect(response.body).to include("stronger, different action")
    end

    it "reflects stored preferences in the rendered controls" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 4.0 }, excluded_section_kinds: [ "parsons_problem" ])

      get setup_path

      expect(response.body).to include(%(id="weight-challenge" min="0" max="4" step="1" value="4"))
      expect(response.body).to match(/id="exclude-parsons_problem"[^>]*checked/)
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/api_keys_spec.rb -e "rotatable kind"`
Expected: FAIL — the body contains none of those ids.

- [ ] **Step 3: Add the locale strings**

In `config/locales/en.yml`, add a top-level block at the same indentation as `sections:`:

```yaml
  exercise_mix:
    summary: "Exercise mix"
    intro: "Bias how often each rotating section appears. This changes which kind fills a slot, not how many sections a day holds."
    third_group: "Rotating third section"
    fourth_group: "Rotating fourth section"
    exclude_heading: "Excluding is a stronger, different action than turning a slider down."
    exclude_body_weak: "A slider at Much less means rarely — the section can still come up, and it will if you haven't seen it in a long while, so nothing disappears from your rotation permanently."
    exclude_body_strong: "Exclude means never. The section is removed from rotation entirely and will not appear again until you turn it back on."
    exclude_label: "Exclude"
    last_in_slot: "At least one section in this group has to stay in rotation."
    stops:
      - "Much less"
      - "Less"
      - "Default"
      - "More"
      - "Much more"
```

- [ ] **Step 4: Add the control to the view**

In `app/views/api_keys/edit.html.erb`, insert this block immediately after the `adaptive-set-size` `div.form-field` and before the existing `<script>`:

```erb
  <details class="form-field" id="exercise-mix">
    <summary><%= t("exercise_mix.summary") %></summary>
    <p class="hint"><%= t("exercise_mix.intro") %></p>

    <div class="mix-note">
      <strong><%= t("exercise_mix.exclude_heading") %></strong>
      <p class="hint"><%= t("exercise_mix.exclude_body_weak") %></p>
      <p class="hint"><%= t("exercise_mix.exclude_body_strong") %></p>
    </div>

    <% { third: t("exercise_mix.third_group"), fourth: t("exercise_mix.fourth_group") }.each do |slot, group_label| %>
      <fieldset class="mix-group">
        <legend><%= group_label %></legend>

        <% ExerciseSection.slots.fetch(slot).each do |kind| %>
          <%
            stored   = current_user.section_kind_weights[kind.key]
            index    = KindPreferences::MULTIPLIERS.index(stored) || KindPreferences::MULTIPLIERS.index(KindPreferences::DEFAULT_MULTIPLIER)
            excluded = current_user.excluded_section_kinds.include?(kind.key)
          %>
          <div class="mix-row" data-slot="<%= slot %>" data-kind="<%= kind.key %>">
            <label for="weight-<%= kind.key %>"><%= t("sections.#{kind.key}.name") %></label>
            <input type="range" id="weight-<%= kind.key %>" min="0" max="4" step="1"
                   value="<%= index %>" <%= "disabled" if excluded %>
                   aria-describedby="weight-label-<%= kind.key %>">
            <output id="weight-label-<%= kind.key %>"><%= t("exercise_mix.stops")[index] %></output>
            <label class="mix-exclude" for="exclude-<%= kind.key %>">
              <input type="checkbox" id="exclude-<%= kind.key %>" <%= "checked" if excluded %>>
              <%= t("exercise_mix.exclude_label") %>
            </label>
          </div>
        <% end %>

        <p class="hint mix-last-note" hidden><%= t("exercise_mix.last_in_slot") %></p>
      </fieldset>
    <% end %>
  </details>
```

Add to the `<style>` block at the top of the same file:

```css
  .mix-group { border: 1px solid var(--border); border-radius: 6px; padding: .75rem; margin-bottom: .75rem; }
  .mix-group legend { font-size: .8rem; color: var(--muted); padding: 0 .35rem; }
  .mix-row { display: grid; grid-template-columns: 1fr auto; gap: .25rem .5rem; align-items: center; margin-bottom: .6rem; }
  .mix-row input[type="range"] { grid-column: 1 / -1; width: 100%; }
  .mix-row output { font-size: .8rem; color: var(--muted); }
  .mix-row input[type="range"]:disabled { opacity: .4; }
  .mix-exclude { font-size: .8rem; color: var(--muted); }
  .mix-note { border-left: 3px solid var(--accent); padding-left: .6rem; margin: .5rem 0 1rem; }
```

- [ ] **Step 5: Wire the script**

Inside the existing IIFE in that file's `<script>`, after the `adaptive` listener, add:

```js
      const STOPS  = <%= raw KindPreferences::MULTIPLIERS.to_json %>;
      const LABELS = <%= raw t("exercise_mix.stops").to_json %>;
      const mix    = document.getElementById("exercise-mix");

      if (mix) {
        const rows = Array.from(mix.querySelectorAll(".mix-row"));

        const state = () => {
          const weights = {};
          const excluded = [];

          rows.forEach((row) => {
            const kind = row.dataset.kind;
            const slider = row.querySelector("input[type=range]");
            const box = row.querySelector("input[type=checkbox]");
            const value = STOPS[Number(slider.value)];

            if (box.checked) excluded.push(kind);
            // Sparse on purpose: a kind left at the default stores no key, so
            // "untouched" and "set back to default" are one stored state.
            if (value !== 1) weights[kind] = value;
          });

          return { section_kind_weights: weights, excluded_section_kinds: excluded };
        };

        // A group's last remaining kind cannot be excluded. The server
        // validation is the authority; this only stops the UI offering it.
        const lockLastInGroup = () => {
          mix.querySelectorAll(".mix-group").forEach((group) => {
            const boxes = Array.from(group.querySelectorAll("input[type=checkbox]"));
            const remaining = boxes.filter((box) => !box.checked);
            const locked = remaining.length === 1;

            remaining.forEach((box) => { box.disabled = locked; });
            group.querySelector(".mix-last-note").hidden = !locked;
          });
        };

        let pending;
        const saveMix = () => {
          clearTimeout(pending);
          pending = setTimeout(() => save(state()), 400);
        };

        rows.forEach((row) => {
          const slider = row.querySelector("input[type=range]");
          const box = row.querySelector("input[type=checkbox]");
          const label = row.querySelector("output");

          slider.addEventListener("input", () => {
            label.textContent = LABELS[Number(slider.value)];
            saveMix();
          });

          box.addEventListener("change", () => {
            slider.disabled = box.checked;
            lockLastInGroup();
            saveMix();
          });
        });

        lockLastInGroup();
      }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/requests/api_keys_spec.rb`
Expected: PASS — 4 new examples plus every pre-existing one.

- [ ] **Step 7: Run RuboCop**

Run: `bundle exec rubocop app config db`
Expected: no offenses.

- [ ] **Step 8: Commit**

```bash
git add config/locales/en.yml app/views/api_keys/edit.html.erb spec/requests/api_keys_spec.rb
git commit -m "Add the exercise-mix control to /setup"
```

---

### Task 9: System spec for the wiring

The lock and the label are script-driven and read server-rendered constants — the class of bug `learn_filter_spec.rb` exists for, where correct HTML still misbehaves in a running page.

**Files:**
- Create: `spec/system/exercise_mix_spec.rb`

**Interfaces:**
- Consumes: the DOM contract from Task 8, `create_fake_provider_user` and `visit_as` from `spec/support/auth_helpers.rb`.

- [ ] **Step 1: Write the test**

Create `spec/system/exercise_mix_spec.rb`:

```ruby
require "rails_helper"

# The sliders persist through an inline listener that PATCHes /profile — no form
# submit, no Turbo. A request spec exercises that endpoint directly, so it stays
# green even if the listener is deleted or posts the wrong stop; only a real
# browser round trip covers the wiring between the two.
RSpec.describe "Exercise mix", type: :system do
  let(:user) { create_fake_provider_user }

  # The fetch resolves independently of Capybara, so the assertion waits on the
  # write rather than the DOM, which already shows the new state optimistically.
  def weights_after_save(timeout: 5)
    deadline = Time.current + timeout
    sleep 0.1 while user.reload.section_kind_weights.empty? && Time.current < deadline
    user.reload.section_kind_weights
  end

  it "saves a slider's stop and shows its label" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click
    find("#weight-challenge").set(0)

    expect(find("#weight-label-challenge")).to have_text("Much less")
    expect(weights_after_save).to eq("challenge" => 0.25)
  end

  it "locks the last remaining kind in a group rather than letting a slot empty" do
    visit_as(user)
    visit setup_path

    find("#exercise-mix summary").click

    ExerciseSection.fourths.first(ExerciseSection.fourths.size - 1).each do |kind|
      find("#exclude-#{kind.key}").click
    end

    last = ExerciseSection.fourths.last

    expect(find("#exclude-#{last.key}")).to be_disabled
    expect(page).to have_text("At least one section in this group has to stay in rotation.")
  end
end
```

- [ ] **Step 2: Run the spec**

Run: `bundle exec rspec spec/system/exercise_mix_spec.rb`
Expected: PASS (2 examples). Requires the one-time Playwright CLI install described at the top of `spec/support/system_test_helper.rb`.

- [ ] **Step 3: Run the whole suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS, 0 failures.

Run: `bundle exec rspec spec/system`
Expected: PASS, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add spec/system/exercise_mix_spec.rb
git commit -m "Cover the exercise-mix wiring in a real browser"
```

---

### Task 10: Remove the planning docs and open the PR

Planning material stays out of the PR by standing preference.

- [ ] **Step 1: Delete the spec and plan**

```bash
git rm docs/superpowers/specs/2026-09-14-section-kind-weight-preferences-design.md
git rm docs/superpowers/plans/2026-09-14-section-kind-weight-preferences.md
git commit -m "Remove planning docs from the branch"
```

- [ ] **Step 2: Confirm the branch is still attached**

Run: `git status --branch --short`
Expected: `## feature/section-kind-weight-preferences`. (`gh` can detach HEAD — check this before and after any `gh` call.)

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feature/section-kind-weight-preferences
```

The PR description must state, since CLAUDE.md requires naming any departure from an in-repo pattern:
- that `effective_weight = staleness × user_multiplier` applies only in the weighted branch, with starvation above it;
- that exclusions subtract from `slot_staleness` while weights deliberately do not, and why;
- that `SectionRotation.eligible` falls back to the unfiltered list if exclusions would empty a slot, as a backstop to the `User` validation.

- [ ] **Step 4: Run the code-review pass**

A strict review pass is a standing step once a PR is authored.
