# Single initial exercise

Each new daily set starts with one engineering exercise. `DaySize.initial`
supplies a count of one without consulting the competency gate. The Daily
sections control is retired. Stored counts and profile validation remain for
compatibility, and the historical competency gate, coverage and cadence remain
available for interpreting older records.

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

`PracticeSchedule::SingleSlot` ranks eligible kinds by oldest service in the generated language first.
A mixed-language learner keeps separate Ruby/Rails and JavaScript service,
so an even kind rotation cannot permanently pair a kind with only one language.
Among kinds with equal service, priority goes to a host for a normal retry,
then pending practice or struggle, reinforcement, retention and a drill.
Among otherwise equal kinds, the regular pair takes precedence. For the
remaining tie, `WeightedRoll.pick` samples the candidates in registry
order. Regular kinds use the default multiplier. Stored multipliers apply
only to tied optional kinds. Seeding Ruby's random source makes the
weighted tie reproducible. A need that persists cannot keep a
recently served kind ahead of an older eligible kind.

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

Deploy the schema and compatible manifest readers first. Then release the
format-3 reader checkpoint (`82bdbb63`). Before releasing the single-exercise
writers, verify web and worker are on compatible revisions and retire older
writers. Once format-3 notes exist, the rollback floor must retain
compatible writers for both initial generation and regeneration. The
reader-only checkpoint by itself is insufficient after that point. The earlier
format-2 checkpoint cannot decode format 3 and is not a compatible rollback. Rollout
uses release ordering and introduces no new flags.
[Daily practice compatibility](daily-practice-compatibility.md)
