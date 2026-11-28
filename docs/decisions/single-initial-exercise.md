# Single initial exercise

Each new daily set starts with one engineering exercise. `DaySize.initial`
supplies a count of one without consulting the competency gate. The Daily
sections control is retired. Stored counts, profile validation and historical
record readers remain for compatibility. Historical sets use their stored
layout and schedule notes use the format-specific decoders described below.
Cleanup of obsolete planning algorithms is tracked separately in
[#862](https://github.com/hmccutchen/code-gym-rails/issues/862).

The planner requests one kind from the provider and runs the existing judging
and retry pipeline for it. A successful save writes one active key to
`section_order` in the same transaction as the exercise. A rejected or failed
draft earns no service. When the judge drops the only section, the existing
retry flow applies. Historical sets without a manifest resolve active keys
from their stored layout. Grading, mastery receipts and completion continue
to use the committed active sections and existing evidence rules.

## Choosing the kind and concept

The stored regular pair supplies preference evidence. Eligible optional kinds
can take the slot if allowed by the pool and the user's exclusions.
`DayHosts` decides whether a kind can carry a learning need for the day's
language, mode and concept restrictions. Weekend bug hunts retain their mode rules and cannot carry a
core retention assignment.

`PracticeSchedule::SingleSlot` normally ranks eligible kinds by oldest
successful delivery in the generated language. A mixed-language learner
keeps separate Ruby/Rails and JavaScript service.

An overdue learning opportunity can override that order. Let N be the current
eligible kind count. After N successful same-language deliveries without a
planning-host delivery of a kind, a currently hostable learning need lets
that kind use its older planning-host service timestamp. A Bug Hunt advances
ordinary delivery service but cannot erase this wait for core practice.
A successful core-practice delivery advances both kinds of opportunity.
This measures opportunities offered, not answers, grades or mastery.

Among equal service ages, priority goes to a host for a normal retry, then
pending practice or struggle, reinforcement, retention and a drill. Among
otherwise equal kinds, the regular pair takes precedence. `WeightedRoll.pick`
settles the remaining tie in registry order. Regular kinds use the default
multiplier; stored multipliers apply only to tied optional kinds.

The history window covers at least twice the eligible kind count and is
filtered by generated language before limiting rows. Delivered section
eligibility comes from the kind's existing evidence rules, including the
stored Bug Hunt shape. A historical row without a schedule sequence has
unknown old host service, represented by zero; do not invent a global
sequence from a language-filtered position. The waiting threshold uses
same-language history positions, while ordering uses recorded service
sequences. No new continuation field or schema is needed.

This gives ordinary variety and overdue learning opportunities separate
claims on the single slot. With a stable eligible pool, ordinary kinds wait
at most 2N successful same-language turns: another kind can move ahead for
its ordinary delivery and its older host opportunity, then both are newer.
The persisted weekly-mode regressions cover support, normal retry and
mixed-language practice with retention and drills.

This finite history window does not promise a universal deadline for a
rarely hostable need: old opportunities can fall outside it between eligible
days. Calendar-day waits also cannot be bounded when the
learner does not practice or the language, mode or concept restrictions
never permit the need. Individual concepts still use the existing
assignment policy below; an offered host is not a promise that every pending
concept is served at once.

Enrolled protected-practice accounts use `PracticeSchedule::Assignments`
with the selected host alone. Its service records are also scoped to the
generated language; otherwise alternating languages could permanently receive
only practice or only maintenance. The assignment algorithm is unchanged:
records alternate practice with
maintenance on a contested host, and retention with drills within
maintenance. Overdue ordering still applies among retention checks.
Inactive accounts filter delivered history to the generated language before
applying the history limit for kind selection and the existing
concept guidance on the selected host. They write no protected-practice
schedule. Unhosted needs remain eligible, and existing reviewed evidence
rules still resolve retention checks, drills and practice requests.

## Schedule continuation and release

The format-3 protected-practice note keeps the schedule policy number, turn
sequence, readiness marker, regular kinds, selected kind and assignment.
Its continuation holds two maps keyed by generated language: `kind_service`
(last successful turn by kind) and `service` (the existing assignment lane,
maintenance lane and recent practice concept records by kind). Format 1
retains its strict variety/pair/pair decoder; format 2 retains its strict
flat kind-service and assignment-service decoder.

When translating format 1 or 2, kind service is seeded from delivered
history in the generated language, never from format 2's global kind map.
The predecessor sequence minus that filtered history index supplies the
service sequence, with a floor of zero. Dropped sections earn no service.
Without a predecessor, the filtered history length supplies the starting
sequence. A language first encountered under format 3 is seeded the same way.

Legacy assignment concepts retain their sequence in each applicable language
map, using `ConceptBucket` to determine applicability. Shared-bucket records
can appear in both maps; these are scheduling bookmarks, not duplicate grades
or mastery evidence. Legacy lane bookmarks reset to nil because their
language cannot be recovered. The first contested assignment can therefore
choose practice before maintenance once; subsequent assignments alternate
independently in each language. No pending request, drill or due date is cleared.
Schedule-note format and mastery receipt policy remain independent.

Generation captures the predecessor under the owner lock, makes provider
calls outside the transaction and verifies the capture again under the lock
before saving. If another job has saved the day, that existing set wins.
If the predecessor changed, return the existing retryable outcome and
discard the stale candidate. This check makes no replacement provider call.
Regeneration reuses the original turn and preserves its service counters. It keeps the original kind when the row recorded a
single kind and it remains eligible. A format-1 or format-2 replacement translates
the continuation without spending service.

Deploy the PR0 schema and compatible manifest readers first. Prepare the
reader release from PR0 by applying only the reader patches `6f763795` and
`82bdbb63`. Its legacy writers remain unchanged: decoding formats 2 and 3
does not make generation or regeneration compatible with those formats.
`82bdbb63` itself is not a reader-only release:
its ancestry already enables format-2 writers, which PR0 cannot read.
Before any PR1 writer starts, stop manual and cron admission of generation
and regeneration, stop or drain every legacy writer including reader-stage
web and worker processes, replicas, one-offs and in-flight provider calls,
and verify none can resume. Deploy and verify the functional release on
both web and worker before resuming admission. No legacy and new writers
may overlap. This requires temporary generation and regeneration
unavailability and introduces no feature flag. The schema, loaded metadata,
format-1/2/3 writer-test and artifact verification gates are in
[Daily practice compatibility](daily-practice-compatibility.md).

After the first new-format note is committed, fix forward or roll back only
to a compatible functional release supporting both initial generation and
regeneration. Never roll back to the reader-only release or delete or reset
notes to permit a rollback. The earlier format-2 checkpoint cannot decode
format 3 and is not a compatible rollback.
