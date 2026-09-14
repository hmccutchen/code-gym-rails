# User-adjustable weight preferences per section kind

Date: 2026-09-14

## What this is

Per-kind controls letting an engineer bias how often each rotating section kind
appears, plus a separate action to remove a kind from rotation entirely.

The need is real-world context the app cannot infer: someone whose current
project is all planning documents gets plan-review practice every day at work
and wants less of it here. Nothing in `recent_performance` can tell the
difference between that and avoidance, so it has to be stated.

Two controls per kind, deliberately not one:

- a **weight**, five stops from ×0.25 to ×4, default ×1 — leans the dial
- an **exclude** toggle — removes the kind from rotation

The distinction between them is the point of this document. A weight at its
minimum means *rarely*; only the toggle means *never*.

## Scope

In: which kind fills the rotating third and fourth slots.

Out, explicitly:

- `code_review`'s content modes (`application_code` / `test_file` /
  `schema_review`) and the `RealSource` sub-roll. This is kind-level selection
  only, never intra-kind content.
- `ConceptMastery`, retention scheduling, tier state. This decides which *kind*
  of section appears, never which concept fills it.
- How many sections a day holds. That is `SectionCount` and the
  `adaptive_set_size` toggle, and stays untouched.

This is a content-curation preference, not a mastery signal. It must never read
from or expose tier state.

## The mechanism it layers onto

`SectionRotation.for` makes two separate decisions, and conflating them is the
easiest way to get this wrong.

**Which slots fill.** `pattern`, `third` and `fourth` are ranked by
`slot_staleness` — the maximum staleness among that slot's kinds — with ties
broken by registry index, and the top `available` win. Fully deterministic; no
roll.

**Which kind fills a chosen slot.** `pick_kind` has two branches:

- any kind staler than `STARVATION_LIMIT` is taken outright, most stale first,
  ties in registry order — no roll;
- otherwise `WeightedRoll.pick` over `staleness` weights.

Staleness is the kind's index in the last `LOOKBACK` entries plus one, or
`LOOKBACK + 1` when unseen.

So exactly one probability exists in the whole object, and it is the second
branch of `pick_kind`. That is the only place a user weight belongs.

## The composition formula

```ruby
def self.pick_kind(slot, recent, preferences)
  kinds   = eligible(slot).reject { |kind| preferences.excluded?(kind) }
  starved = kinds.select { |kind| staleness(kind, recent) > STARVATION_LIMIT }

  return most_stale(starved, recent).key.to_sym if starved.any?

  weights = kinds.index_with { |kind| staleness(kind, recent) * preferences.multiplier_for(kind) }
  WeightedRoll.pick(weights).key.to_sym
end
```

`effective_weight = staleness × user_multiplier`.

There is no base-weight term, because there is none today — the comment in
`section_rotation.rb` records that removal as deliberate ("no base-weights table
multiplied in"). Reintroducing one would be a regression, not a composition.

Three invariants, each separately testable:

1. **The multiplier appears on exactly one line**, inside the non-starved
   branch.
2. **The starvation branch never reads a multiplier.** It returns before the
   weights are built. This is what makes "a low weight cannot starve a kind"
   structurally true rather than asserted.
3. **Exclusion is the only thing that removes a kind from the pool**, and it is
   applied before the starvation check. A ×0.25 kind is still in `kinds` and
   still starvation-eligible; an excluded kind is in neither.

### Weights do not touch slot choice; exclusions do

Weights apply only in `pick_kind`. Slot filling stays exactly as it is today.
Down-weighting every third-slot kind does not make the third slot skip in favour
of `pattern` on a short day; it changes only which third you get when that slot
wins.

The reason is that a preference about *which kind* would otherwise start
deciding *whether a slot exists*, which is a different axis — set shape, already
owned by `SectionCount` and the `adaptive_set_size` toggle.

Exclusions are the deliberate asymmetry. `slot_staleness` is a `max` over a
slot's kinds, so an excluded kind left in that computation could pull its slot
into a scarce spot on the strength of a kind that can never fill it. Exclusions
therefore subtract from `slot_staleness` too. Weights: kind pick only.
Exclusions: pool membership, everywhere the pool is read.

### What the dial can actually do

The starvation guarantee compresses the low end, and this is a property of the
design rather than a defect.

A kind reaching `staleness > STARVATION_LIMIT` is taken outright whatever its
weight. With four third-slot kinds competing, a down-weighted kind therefore
still resurfaces after roughly `STARVATION_LIMIT` third-slot days instead of at
its unweighted rate. Upweighting has no equivalent ceiling.

So the low end leans; it does not silence. The UI copy states this outright
rather than implying a linear dial, and it is why the exclude toggle has to
exist as its own action.

### Re-enabling a kind

An excluded kind accrues staleness while excluded — nothing removes it from
history, and it simply is not in the pool. Re-enabling one therefore returns it
at maximal staleness, so it will almost certainly be force-picked by the
starvation branch within a day or two. This is intended ("I turned it back on
and got it"), and is recorded here so it reads as designed rather than
discovered.

## Persistence

**Migration required** — `AddSectionKindPreferencesToUsers`:

```ruby
add_column :users, :section_kind_weights,   :jsonb, default: {}, null: false
add_column :users, :excluded_section_kinds, :jsonb, default: [], null: false
```

Additive, defaulted, no backfill, no index, no data migration. Every existing
row arrives at `{}` / `[]`, which reads as "×1 for everything, nothing
excluded" — so the migration alone is behaviour-neutral, and a spec asserts that
rather than assuming it.

**jsonb on `users`, not a new table.** `focus_areas` is already
`jsonb, default: [], null: false` on this table. Nothing queries, filters, joins
or aggregates across these values; they are read once per generation, for one
user, whole. A normalized table would add a model, a migration and an N+1 risk
for no gain — YAGNI.

**Two columns, not one nested blob.** A single
`{"challenge" => {"weight" => 0.5, "excluded" => true}}` makes "turned down" and
"excluded" two fields of one fact, reintroducing at the storage layer exactly
the conflation the UI copy exists to prevent. The two are also read differently:
a weight is a per-kind lookup with a default, an exclusion is set membership.

**Sparse, so default has one representation.** Only non-default entries are
written; returning a slider to ×1 deletes its key rather than storing `1.0`.
"Untouched" and "explicitly set to default" are the same stored state.

```
section_kind_weights:   { "plan_review" => 0.25, "security_review" => 2.0 }
excluded_section_kinds: [ "parsons_problem" ]
```

**Which kinds get a control is derived**, on `ExerciseSection` (which already
owns per-kind questions and slot shape):

```ruby
def self.rotatable
  slots.values.select { |kinds| kinds.size > 1 }.flatten
end
```

That yields the four thirds and three fourths, and omits `code_review` and
`pattern` mechanically rather than by decision: their slots hold one candidate,
and a weighted roll over one key returns it at any weight, so a control there
would provably do nothing. A ninth kind added to a slot gets a control with no
edit here.

**Track independence needs no machinery.** Weights are keyed by kind, and
`pick_kind` is called per slot with only that slot's `eligible` list. A
`plan_review` weight is never in scope when the third slot rolls, because
`plan_review` is not in `eligible(:third)`. `WeightedRoll` normalizes within the
hash it is handed, which is one slot's kinds. A spec pins it; nothing enforces
it beyond the existing shape.

**`anonymize!` needs no edit.** It clears identity, credentials and
reach-the-user intent (`reminder_level`, push endpoints) and deliberately leaves
preferences — `focus_areas`, `adaptive_set_size`, `language`, `skill_level`.
These follow that precedent.

## `KindPreferences`

`app/models/kind_preferences.rb` — a pure value object, beside `ConceptBucket`
and `RealSource` (`app/services` holds the decision objects; this decides
nothing).

```ruby
class KindPreferences
  MULTIPLIERS        = [ 0.25, 0.5, 1.0, 2.0, 4.0 ].freeze
  DEFAULT_MULTIPLIER = 1.0

  def self.none      = new(weights: {}, excluded: [])
  def self.for(user) = new(weights: user.section_kind_weights, excluded: user.excluded_section_kinds)

  def multiplier_for(kind)
    value = @weights[kind.key]
    MULTIPLIERS.include?(value) ? value : DEFAULT_MULTIPLIER
  end

  def excluded?(kind) = @excluded.include?(kind.key)
end
```

`SectionRotation.for`'s new kwarg defaults to `KindPreferences.none`, so every
existing caller and spec keeps working and "no preferences" is a real object
rather than nil checks inside `pick_kind`. This follows `SectionCount.for`'s
precedent of taking plain values rather than a `User`, which is what keeps these
specs free of the database.

The read-side fallback in `multiplier_for` is not a second copy of the
validation: `MULTIPLIERS` is one constant with two readers. It exists because
the object must be total. A `0` reaching `WeightedRoll` would make a kind
unpickable below starvation — silently recreating the failure mode this design
exists to prevent — and a negative would corrupt the cumulative sum for every
other kind in that slot. A hand-edited row degrades to ×1 instead.

## Validation

Three validations on `User`, all derived from the registry:

```ruby
validate :section_kind_weights_name_rotatable_kinds   # keys ⊆ ExerciseSection.rotatable, values ∈ MULTIPLIERS
validate :excluded_section_kinds_name_rotatable_kinds # entries ⊆ ExerciseSection.rotatable
validate :every_slot_keeps_a_kind
```

The third refuses an exclusion that would empty a slot:

```ruby
def every_slot_keeps_a_kind
  ExerciseSection.slots.each do |slot, kinds|
    next if kinds.size <= 1
    next if kinds.any? { |kind| !excluded_section_kinds.include?(kind.key) }

    errors.add(:excluded_section_kinds, "must leave at least one #{slot} section in rotation")
  end
end
```

Excluding is per-kind curation, never a way to delete a whole slot. Allowing an
empty slot would let the day render fewer sections than `SectionCount` asked
for, which then lowers the completion mean, which shrinks the set further — a
compounding drift for a reason unrelated to completion. Refusing keeps
`SectionRotation`'s contract intact: a slot that wins a spot always yields a
kind.

Derived from `ExerciseSection.slots`, so it covers third and fourth today and
any future multi-kind slot with no edit.

## The boundary

`ProfileController`, the surface that already autosaves `adaptive_set_size`:

```ruby
permit(:name, :time_zone, :adaptive_set_size, section_kind_weights: {}, excluded_section_kinds: [])
```

Two sharp edges:

1. `permit(section_kind_weights: {})` returns `ActionController::Parameters`,
   not a `Hash`, and assigning that to a jsonb attribute is a serialization
   hazard. `profile_params` converts explicitly with `.to_h`, the same
   defensive shaping it already does for `:name` and `:time_zone`.
2. JSON numbers, not strings. `"0.25"` is rejected with the existing 422 JSON
   shape, following the `BOOLEAN_VALUES` precedent already in this controller —
   Active Record's cast is too forgiving for a request boundary. The inline
   script sends numbers, so this fires only on a malformed request.

**Writes are full replacement, not a patch.** Each save posts the complete
sparse state of both fields. A merge-style patch would need a separate "delete
this key" signal to express "back to default", which is a second way to say what
sparseness already says once.

## UI

A collapsed `<details>` block titled "Exercise mix" on `/setup`, below the
`adaptive_set_size` checkbox, holding two groups: **Rotating third section** and
**Rotating fourth section**.

`/setup` is where the preferences that shape what generation produces already
live — language, time zone, adaptive sizing — and `PATCH /profile` already
autosaves them. The disclosure keeps a 480px first-run page focused on its
primary job of accepting an API key; disclosures are an existing idiom here.

Row labels are `t("sections.#{key}.name")`, never a humanized key.
`spec/system/learn_filter_spec.rb` exists because a humanized label and a
rendered label drifted apart where no request spec could see it.

The slider is `<input type="range" min="0" max="4" step="1">` — an index into
`KindPreferences::MULTIPLIERS`, rendered into the page from the server. The DOM
never holds `0.25`, which removes float equality from the script and guarantees
the posted value is a member of the constant rather than something that rounds
to one. This follows the `ANSWER_MIN_LENGTH` precedent of the script reading the
rule from the server instead of restating it. A live `<output>` shows the stop's
words: Much less / Less / Default / More / Much more.

Saving reuses the page's existing inline `save()` helper, debounced ~400ms since
a range input fires continuously while dragging.

### Copy

Above the exclude column:

> **Excluding is a stronger, different action than turning a slider down.**
>
> A slider at **Much less** means *rarely* — the section can still come up, and
> it will if you haven't seen it in a long while, so nothing disappears from
> your rotation permanently.
>
> **Exclude** means *never*. The section is removed from rotation entirely and
> will not appear again until you turn it back on.

This separates the two actions and is simultaneously honest about the starvation
floor: "Much less" genuinely cannot mean "never", so the copy says so rather
than implying a dial that reaches zero.

The disclosure summary also notes that these settings shape which kind fills a
slot, not how many sections a day holds — otherwise they will be read as one
control with `adaptive_set_size` directly above.

### States

1. **Excluding disables that row's slider** (`aria-disabled`), since a weight on
   an excluded kind is unreachable. The stored value is left alone, so
   un-excluding restores the slider where it was.
2. **The last un-excluded kind in a group has its checkbox disabled**, with
   inline text naming why. The client recomputes per group on each change. The
   `User` validation remains the authority; this is convenience, and a 422 from
   a stale tab still renders through the existing error path.

## Testing

Deterministic wherever possible. `WeightedRoll` calls `rand` on its own class,
so `allow(WeightedRoll).to receive(:rand)` makes the roll exact — these assert
the formula, not a tendency.

Carrying the core constraint:

1. **The multiplier composes as stated.** Two kinds at equal staleness, one at
   ×4. The cumulative boundary sits at `4/(4+1) = 0.8`, so `rand → 0.79` picks
   the weighted kind and `rand → 0.81` picks the other. A base-weight term or a
   different composition moves the boundary and fails.
2. **Starvation is unreachable by the multiplier.** Age a ×0.25 kind past
   `STARVATION_LIMIT` and stub `WeightedRoll.pick` to raise. Passing proves the
   roll was never reached — structural, not probabilistic.
3. **Exclusion precedes starvation.** An excluded kind at maximal staleness is
   never returned, proving exclusion removes it from the pool rather than losing
   a roll.

Pinning the decisions:

4. **Weights never touch slot choice.** Identical history, extreme weights on
   every third-slot kind, `count: 2` — the same slot fills as with no
   preferences.
5. **Exclusions do subtract from `slot_staleness`.** A slot whose only stale
   kind is excluded loses the spot.
6. **No cross-track leakage.** A `plan_review` weight leaves the third-slot
   distribution identical under a fixed `rand`.
7. **`KindPreferences.none` reproduces current behaviour**, modelled on
   `provider_request_characterization_spec.rb`, which pins that an empty
   `history:` serializes identically at the `#call` boundary. This is also what
   makes the migration provably behaviour-neutral for existing rows.

Database-backed:

8. `User` validations — unknown kind key, off-stop value, excluding the last
   kind in a slot, excluding all but one.
9. `ProfileController` — a string `"0.25"` is a 422, the `Parameters`→`Hash`
   conversion persists, and posting a smaller hash clears omitted keys.
10. `DailyPlan` passes the user's preferences through to `SectionRotation`.

One system spec: the last-checkbox lock and the slider's label output are
script-driven and rendered from server-supplied constants — the class of bug
`learn_filter_spec.rb` was written for, where correct HTML still misbehaves in a
running page. Against the `FakeService` user, per existing convention.

The mastery constraint is held structurally rather than by a test that greps:
`SectionRotation` receives history and preferences, `KindPreferences` reads two
user columns, and neither is handed anything that leads to `ConceptMastery`. A
spec pins the constructor signature, the way `#assess_difficulty`'s deliberately
narrow signature is pinned, so it cannot be widened silently.

## Files

New:

- `app/models/kind_preferences.rb`
- `db/migrate/*_add_section_kind_preferences_to_users.rb`
- specs per above

Changed:

- `app/services/section_rotation.rb` — the `preferences:` kwarg, the multiplier
  in `pick_kind`, exclusions subtracted from the pool and from `slot_staleness`
- `app/services/daily_plan.rb` — passes `KindPreferences.for(user)`
- `app/models/exercise_section.rb` — `.rotatable`
- `app/models/user.rb` — three validations
- `app/controllers/profile_controller.rb` — permitted params, strict value check
- `app/views/api_keys/edit.html.erb` — the disclosure, rows, copy, script
- `config/locales/en.yml` — control labels and copy
