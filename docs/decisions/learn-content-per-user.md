# Learn content belongs to each user

**Decision (2026-11-13, owner).** Concept references and recognition guides
become separate for each user. Until now `concept_references` (unique on
concept and language) and `recognition_guides` (unique on group key) were
shared: the first user whose key asked for a row paid for it, and every
teammate saw the same text. From now on each user owns their own rows,
written with their own key.

The owner decided:

- **Content is per user.** Each user has their own `ConceptReference` rows,
  keyed on user, concept and language.
- **Recognition guides are per user too**, keyed on user and group key.
- **Existing shared rows are copied to every current user, then
  removed.** Nobody loses text they can see today, and nobody pays for it
  again. The copy goes to active accounts only, never to an anonymized one.
- **The automatic write-up on submit stays.** Submitting a day still queues
  write-ups for the concepts it touched. Generating a set also queues them,
  so the text is ready sooner.
- **Bulk "prepare" jobs run behind the morning scheduled sets.** A bulk
  write-up never delays a user's daily set.
- **`script/junior_ladder_preparation.rb` is retired**, with
  `script/prepare_junior_ladders.rb`, the runner that loads it. Per-user
  writing replaces what it prepared for everyone.
- **Trial accounts get no Learn content generation.** Trials are paused, so
  no trial account writes a reference or guide on the house key.
- **`SuggestedConcept` stays shared.** It is an admin queue of concept tags,
  not text a user reads.

## Account deletion

A user's own rows go when the account is deleted
(`AccountData::FATES`, `deleting-an-account.md`). Since L2, every reference
read and write goes through `user_id`, so deletion finds the concept
references a user has written. Since L3 the same holds for recognition
guides. Shared rows had no
`user_id`, so deletion left them alone. Since L5 nobody read them, and the
schema step deleted them and made `user_id` NOT NULL, so every row has an
owner and deletion finds every row a user holds.

## Order and deploy gates

The worker can start before the web service has migrated, so a new column
ships one release before any code reads it for Learn
(`.claude/rules/deployment.md`, Migrations). The change ships in six steps:

1. **L1, schema and deletion fate.** Adds a nullable `user_id` (foreign key
   to `users`) to both tables, unique indexes on `(user_id, concept,
   language)` and `(user_id, group_key)`, and turns the old unique indexes
   into partial ones over rows with no user, so code still in production
   keeps deduplicating shared rows. Deletion removes a user's own rows.
2. **L2, per-user concept references (done, apart from the privacy copy
   below).** Reads and writes the user's own reference, falling back to the
   shared row when the user has none. Waits until L1 is deployed. L2 must also:
   - scope `ConceptReference`'s `uniqueness: { scope: :language }` to
     `user_id`;
   - key `GenerateConceptReferenceJob`'s `limits_concurrency` on `user_id`
     as well as language and concept, since its `on_conflict: :discard`
     would otherwise drop another user's job for the same concept;
   - make the job's write survive the user being deleted during the
     provider call: check the user again under a lock before writing, write
     nothing if the account is gone, and never leave a failed job behind on
     `InvalidForeignKey`. A spec deletes the user between the provider call
     and the write. The job joins the "Work in flight" list in
     `deleting-an-account.md` in the same step;
   - update the privacy page copy (`privacy.show`) and the `PrivacyNotice`
     code note, since deletion starts removing a person's write-ups here.
     The privacy page is not on L2's base: it arrives with PR #785. These
     copy changes land in the first pull request opened after both #785
     and L2 are merged, so this item is still open. Since L5 no user reads
     a shared write-up, so that pull request also removes the sentence
     "Concept write-ups your key wrote before Learn became personal are
     shared with everyone and stay until they are retired" from the privacy
     page. L5 does not edit the page, which is not on its branch;
   - update the locale strings that say the wording is shared: Learn's
     `ladder_offer` and `lesson_offer`, and the bulk preparation copy
     (`prepare_cost`, `ladders_cost`) that says what it writes is shared with
     everyone on the team.
3. **L3, per-user recognition guides (done, apart from any privacy copy,
   which follows the same note as L2's).** The same for guides, with the same
   obligations: scope `RecognitionGuide`'s `uniqueness: true` on `group_key`
   to `user_id`; key `GenerateRecognitionGuideJob`'s `limits_concurrency`
   (today `recognition_guide/<group_key>`, with discard) on `user_id` too;
   make its write survive a deletion mid-call, with the same spec, and add
   it to "Work in flight"; and update any privacy or locale copy that still
   calls a guide shared.
4. **L3b, scheduled sets ahead of Learn's bulk prepare (done).** Learn's
   prepare and prepare-ladders presses queued at `JobPriority::BULK`, ahead
   of `JobPriority::SCHEDULED`, so a press could delay a morning set. L3b
   moves that work behind the scheduled sets and lets a single-concept
   click jump the queue (issue #777). It needs no deploy gate. "What L3b
   does" below has the details.
5. **L4, copy shared rows (done).** Copies every shared row to every active
   account. Its deploy gate: L2 and L3 run on both web and worker. Code
   older than L2 writes shared references and code older than L3 writes
   shared guides, so once both run everywhere no writer creates a shared row
   after the copy. L3b writes no shared row, so the gate does not name it;
   the branches stack, so L4 ships with L3b anyway. This is the one
   statement of the gate. "What L4 does" below has the details.
6. **L5, drop the shared fallback (done), then tighten the schema
   (done).** The pull request that removes the fallback also carries a
   data migration that runs the L4 copy again for every active account still missing a copy.
   It runs in the web pre-deploy step, while the code still serving reads
   the shared rows, so every account that exists when the copy reads its
   list of accounts has its own copy before the new web code serves. An
   account created during that deploy, after that read and before the new
   code serves, gets no copy; it sees what any new account sees and
   generates its own, and the schema step's final copy covers a trial,
   which cannot. The worker is not held back by the copy; "The deploy window
   between L4 and L5" below says what that costs. L5's migration must declare `disable_ddl_transaction!`, so the
   copy commits one user at a time; `copy_to_active_users` raises if it is
   called inside a transaction, which would hold every user's lock until
   the end. "What L5 does" below has the details.

   The schema step came in a later, separate pull request. Its migration
   (`RequireUserOnLearnContent`) runs L4's copy a third time, then deletes
   the shared rows, drops the two partial unique indexes over rows with no
   user and makes `user_id` NOT NULL on both tables; the same pull request
   made `belongs_to :user` required on both models. It kept the per-user
   unique indexes. Its deploy gate: L5 runs on both web and worker. An L4
   web or worker still reads the shared rows, so for an account the copy
   missed, one created after it, deleting them early would take text away
   from a page or skip a write-up on old code's say-so. It also runs after
   L5's catch-up copy, which needs the shared rows to copy from. The same
   pull request changed `app/models/account_data.rb` and the fate table in
   `deleting-an-account.md`, which said shared rows "stay", since no shared
   row is left to stay. "What the schema step does" below has the details,
   and "Open question for the owner" says how the gate is checked.

## What L2 does

- L2 made `ConceptReference.for(user, concept:, language:)` and
  `ConceptReference.seen_by(user, ...)` the one answer to which reference a
  user sees. Under L2 that was their own row, else the shared one, never
  another user's. Learn, the dashboard and History inline reference, the
  featured callout, the review's short version, generation's ladders
  (`GenerationLadders.for(user, ...)`), `LadderCoverage` and
  `explain_differently` read through them. "What L5 does" below gives the
  current read.
- From L2, `GenerateConceptReferenceJob` wrote only the user's own row. A
  user with only the shared row who asked for a rewrite got a new row of
  their own, numbered past the shared row's `generation_version` so the
  Learn poll saw the rewrite land; the shared row was never written again.
  L5 changed the numbering.
- The admin promote check (`ConceptReference.written_up?` and
  `.written_up_keys`) counts any row, a teammate's included. It asks
  only whether the concept has ever been written up and shows no text, and
  a reference for a concept outside the vocabulary exists only once
  someone's set was tagged with it.
- Generating a set (a new one or a regeneration) queues the user's missing
  write-ups at `JobPriority::BACKGROUND` once the set is saved, one step
  below the scheduled sets. At `JobPriority::SCHEDULED` they would have
  tied with the sets, and Solid Queue breaks a tie by job id, so a write-up
  from an earlier hour, or from early in the hourly hand-out, would have run
  ahead of a teammate's set enqueued after it. One step lower, they never
  delay a teammate's daily set. It leaves out a
  concept the set hides until it is submitted, so Learn never gains a
  write-up that hints at a hidden answer. Submitting still queues the rest.
- `User#writes_learn_content?` (it replaced `#prepares_ladders?`) gates
  every enqueue path and the job itself, so a trial account writes nothing.
- The preview seed writes the preview user's own row, never a shared one,
  so nothing writes a shared row after L2.
- Which pairs still lack a write-up is `ConceptReference.missing_for(user,
  pairs)`, asked by both Learn's prepare button and
  `GenerateConceptReferenceJob.queue_missing`.
- From L2 until L5, "own wins" was decided per row, not per field: mixing
  fields from two rows would have shown a ladder written for different text.

## What L3 does

- L3 made `RecognitionGuide.seen_by(user, group_keys)` the one answer to
  which guide a user sees (under L3, their own row, else the shared one;
  since L5, their own row only). Learn's index reads it, and `RecognitionGuide.missing_for(user,
  group_keys)` decides which guides the prepare button queues. No endpoint
  finds a guide by id, so there is no cross-user path to close.
- The uniqueness validation on `group_key` is scoped to `user_id`.
- `GenerateRecognitionGuideJob` keys its permit on user and group key.
  Under L3 it skipped the call when the user already saw a guide, their own
  or the shared one; guides are never rewritten. It calls the provider
  outside any lock, then writes the user's own row inside a transaction that
  share-locks the user, and writes nothing once the account is gone. It
  never writes a shared row, and a trial account writes nothing
  (`User#writes_learn_content?`).
- Learn's `prepare_cost` copy no longer says the guides are shared.
- The recognition guide prompt is unchanged: it still takes only the group,
  and no exercise, response or history.

## What L3b does

- Learn's bulk presses (`LearnController#prepare` and `#prepare_ladders`)
  queue at `JobPriority::BACKGROUND`, the priority a saved set's write-ups
  already use. `JobPriority::BULK` is gone, so nothing a press queues runs
  ahead of a scheduled set, even one the hand-out enqueues after the press.
  A step of its own between `SCHEDULED` and `BACKGROUND` would have ordered
  a press ahead of a set's write-ups, and no case needs that order.
  `job_priority_spec` holds the three steps, and a request spec reads
  Solid Queue's claim order to show a later scheduled set is claimed first.
- `GenerateConceptReferenceJob` no longer lets one queued job discard
  another across priorities. Its permit key starts with the job's priority,
  so a click (`JobPriority::CLICK`) for a concept a bulk press already
  queued gets a job of its own and runs at click priority. Two jobs at one
  priority still share a permit, so pressing a button twice queues nothing
  new.
- The job takes a claim when it runs, before the provider call: a
  PostgreSQL advisory lock on the user, language and concept, held through
  `AdvisoryLock.hold` for the call and the write. A job that finds the claim
  held logs a skip and calls nothing, and the job holding it writes the row.
  A job that finds the row already written calls nothing either: it reads
  the row again once it holds the claim, outside the job's query cache,
  which would otherwise answer with the read from before the claim. So when
  the click runs first, the press's job finds the row written; when the
  press's job is already running, the click finds the claim. Either way
  the concept gets one call.
- The claim only keeps two calls from running at once. A ladder press
  queued before a click for one of its concepts would still call after the
  click, whenever the click's reply left the ladder or lesson unwritten, so
  each refresh carries the `generation_version` the user saw when it was
  asked for (`seen_version`, 0 for no row). Under the claim, a job whose
  version no longer matches the row skips the call: a write has landed
  since the request. A later press or click reads the new version and still
  retries. `GenerateConceptReferenceJob.queue_rewrites` builds the argument
  for both Learn entry points. A job queued before this change carries no
  version and runs as before.
- A writer that takes no claim, an older worker during a deploy or a
  migration copying rows, can still add or rewrite the row during the call.
  So the job asks the same question again under the row lock before it
  writes: a plain write-up that now finds a row, or a rewrite whose version
  the row has moved past, writes nothing.
- The claim needs no column. A claim column would have to sit on a row
  that may not exist yet (the user's own reference is created by the job),
  and a claim on `users` would hold back every other concept of that user.
  An advisory lock belongs to the database session, so a worker that dies
  mid-call loses its connection and the lock with it: there is no stale
  claim to wait out. A job only tries the lock and never waits on it, and
  the share lock on the user and the row lock come after it in the same
  order as before (user, then the user's own row), so it adds no lock
  cycle with `AccountDeletion`.
- A session lock needs a direct database connection. A pooler in
  transaction mode, such as PgBouncer, could run the unlock on another
  server session than the lock, so the claim would never be released.
  Railway's `Database` service is reached directly today
  (`.claude/rules/deployment.md`).
- During the deploy, an L3 worker can run a job beside an L3b one for the
  same concept, and the L3 job takes no claim, so both may call. That is
  one extra write-up call at most, for one deploy, and the row lock in
  `#rewrite` and the unique index still keep one row. It needs no gate.
- `GenerateRecognitionGuideJob` keeps its permit with discard and takes no
  claim. Only the bulk press queues a guide, so no click waits on one, and
  its unique index stops a second row when the permit is bypassed.
- The hourly Learn prepare limit (`LearnController::PREPARE_PER_HOUR`) is
  unchanged. It skips accounts with a key of their own (`unless:
  :own_key?`), and since L2 the accounts left, trials on the house key, are
  refused a write-up before anything is queued. So it limits no queued
  work today. Whether it should go, or start counting own-key accounts'
  presses, is the owner's call.

## What L4 does

- The data migration `CopySharedLearnContent` copies every shared
  `concept_references` row and every shared `recognition_guides` row to
  each active account (no `anonymized_at`), every column but `id` and
  `user_id`, so a user sees the same text and the Learn poll sees no
  rewrite.
- Trial accounts get copies too. The owner's rule is active accounts, a
  trial read the shared text through the fallback until L5, and a copy calls
  no provider, so it is not Learn generation.
- An anonymized account gets nothing.
- A row the user already owns stays as it is (the end of "The deploy window
  between L2 and L3").
- It removes no shared row and leaves the fallback in place; L5 removed the
  fallback, and the schema step after it removed the rows.
- `down` does nothing: a copied row cannot be told apart from one the user
  wrote, and deleting it would delete user data.
- Its deploy gate is step 5 above.
- How it runs (one user at a time, the lock order with account deletion,
  the race with a write-up job, and how L5 calls it again) is in
  `docs/code-notes/db/migrate/20261113150000_copy_shared_learn_content.md`.

## What L5 does

- `ConceptReference.visible_to`, `.for`, `.seen_by` and `.missing_for`, and
  `RecognitionGuide.visible_to`, `.seen_by` and `.missing_for`, read only
  the user's own rows. A shared row and another user's row are never read.
  The method names stay, so Learn, the inline references, the review's
  short version, `explain_differently`, `GenerationLadders`,
  `LadderCoverage` and the prepare buttons change nothing. With one row per
  user and key, the "own wins over shared" sort is gone.
- `GenerateConceptReferenceJob` writes a user's first row with
  `generation_version` 1. A rewrite only asks for a row the page showed,
  which is the user's own, and adds one to its number, so the Learn poll
  still sees it land.
- `GenerateRecognitionGuideJob` skips only when the user has their own
  guide. A user with only the shared guide gets their own written.
- The admin promote check (`ConceptReference.written_up?` and
  `.written_up_keys`) still counts any row, as L2 decided.
- The data migration `CatchUpSharedLearnContentCopy` runs L4's
  `CopySharedLearnContent.copy_to_active_users` again, so an account created
  after L4's copy, while L4 code served, gets its copy before the fallback
  goes. Its code note is
  `docs/code-notes/db/migrate/20261113170000_catch_up_shared_learn_content_copy.md`.
- Learn's `ladder_offer`, `lesson_offer` and `ladders_cost` say the call
  rewrites the reference, no longer that it writes "your own version",
  since every reference a user sees is already theirs.

## What the schema step does

- The migration `RequireUserOnLearnContent` first runs L4's copy
  (`CopySharedLearnContent.copy_to_active_users`) once more, then deletes
  every `concept_references` and `recognition_guides` row with no
  `user_id`, drops
  the two partial unique indexes over those rows that L1 created, and makes
  `user_id` NOT NULL on both tables. The per-user unique indexes stay, since
  L4's copy names their columns in its `ON CONFLICT`.
- `ConceptReference` and `RecognitionGuide` declare `belongs_to :user`
  without `optional: true`, so a row with no owner fails validation before
  it reaches the NOT NULL constraint. Their uniqueness validations were
  already scoped to `user_id` and stay as they are.
- The readers keep their names (`visible_to`, `for`, `seen_by`,
  `missing_for`, `written_for?`). `User` gains no `has_many` for the two
  tables: nothing would call it, and `AccountData::FATES` already deletes
  the rows.
- It runs the copy a third time because L5's catch-up reads the list of
  active accounts once, before its loop, so an account created after that
  list was read got no copy. That includes a trial started through
  `/trial/start` with an invite code: trials are paused only by hiding the
  link, and a trial cannot write its own Learn content
  (`User#writes_learn_content?`). Copying again just before the shared rows
  go gives every account that exists then its copy, so the only accounts
  left without one are those created between L5's catch-up and this step,
  which L5 code already shows no shared text. The copy commits one user at
  a time, so the migration declares `disable_ddl_transaction!` and runs the
  delete, the index drops and the NOT NULL change together in a transaction
  of their own.
- `AccountData::FATES` and the fate table in `deleting-an-account.md` no
  longer say shared rows stay.
- Its deploy gate is step 6 above. How it runs (locking, the deploy window
  and rolling back) is in
  `docs/code-notes/db/migrate/20261113190000_require_user_on_learn_content.md`.

## What remains

Nothing in the schema: the schema step ran L4's copy a third time, deleted
the shared rows and made `user_id` NOT NULL. The privacy page copy in step 2
is still open: it lands in the first pull request opened after both #785 and
L2 are merged, and removes the sentence about shared write-ups, which no
longer exist.

## Open question for the owner

The schema step's gate, L5 on both web and worker, is a manual check. No
code can tell an L4 process from an L5 one, and the migration deletes the
shared rows for good: database backups are off, so they cannot be restored.
Before deploying the schema step, the person merging it must confirm on
Railway that both the web and the worker service run L5, and say so in the
pull request.

## The deploy window between L4 and L5

Railway does not order the web and worker deploys. During the rollout a web
or worker still on L4 code reads the shared rows as a fallback, while L5
code reads only own rows. The catch-up copy runs in the web pre-deploy, so by
the time any L5 web code serves, every account that existed when the copy
read its list of accounts owns a copy, and both versions show it the same
text. That holds for web only. The
worker's pre-deploy (`db:wait_for_schema`) waits for a schema, not for
pending migrations, so an L5 worker can run before the copy reaches a
user. It sees no own row, so a queued write-up or guide job makes a billed
call on the user's key and writes a fresh row at version 1, and the copy
then skips that concept (`ON CONFLICT DO NOTHING`). Nothing visible is
lost; the cost is extra provider calls during one deploy. Deploy web first
and let the worker follow once the web pre-deploy has succeeded. The worker
is not gated on the migration (`.claude/rules/deployment.md` says why).

An account created during the deploy, after the catch-up has read its list
of accounts and before the new code serves, gets no copy: L4 code shows it
the shared text, and L5 code shows it what any new account sees and writes
its own. A trial account cannot write its own, and trials can still start
through `/trial/start` with an invite code while the login page hides the
link, so the schema step runs the copy again before deleting the shared rows.
Such an account is without the shared text only between L5 and that step. An L4 worker may
also skip such an account's write-up because it sees the shared row; it is
queued again on the next submit or Learn press. A Learn page that account
rendered under L4 shows the shared row. After L5 its ladder and lesson poll
(`LearnController#status`, `version > param`) does not report the first
own row, written at version 1, and "explain differently" with the shared
row's id answers 404. A reload fixes both. This lasts for one deploy, so it
is accepted.

A rewrite queued by L4 web carries the `seen_version` of the row L4 showed,
which may be the shared row's. An L5 worker compares it with the user's own
row: a copy keeps the shared row's version, so the rewrite runs, but for a
user with no copy yet the versions differ and the job skips. The next press
captures the own row's version and runs.

## The deploy window between L1 and L2

Railway does not order the web and worker deploys, so either service can
run L1 code while the other runs L2.

- **Web still on L1.** The web service can run L1 code after the L2 worker
  has written a user's own row. L1 code looks a reference up by concept and
  language alone, so it may show that row to another user as if it were
  shared. The text is a generic concept explanation and holds nothing
  private.
- **Worker still on L1.** An L1 worker can run a job the L2 web service
  queued. It also looks rows up by concept and language only, so it may
  skip a user's write-up because a teammate's row exists, rewrite a
  teammate's incomplete row from this user's call, or create a shared row
  with no `user_id`. A skipped write-up is queued again on the user's next
  submit or Learn press. A shared row written here is one the L4 copy
  picks up, since L4's deploy gate (step 5) waits for this window to close.

Both cases last for the length of one deploy, so they are accepted.

## The deploy window between L2 and L3

L3 does for recognition guides what L2 did for concept references, so the
same window opens again, with either service on L2 while the other runs L3.

- **Worker still on L2.** An L2 worker can run a guide job the L3 web
  service queued. It checks `RecognitionGuide.exists?(group_key:)` across
  all users, so it may skip this user's guide because a teammate already has
  their own row. It may also create a shared row, with no `user_id`, paid for
  by this user's key. A skipped guide is queued again on the user's next
  Learn press. A shared row written here is one the L4 copy picks up.
- **Web still on L2.** An L2 web service reads guides by
  `where(group_key:)` alone, so after an L3 worker has written a user's own
  row it may show that row to a teammate, and its prepare press leaves out
  a guide a teammate owns. A guide teaches how to look for a kind of problem
  in general and holds nothing private.

Both cases last for the length of one deploy, so they are accepted. L4's
deploy gate (step 5) waits for this window to close too.

L4's copy, and L5's second run of it, must insert a user's copy only where
that user has no row yet: no `(user_id, concept, language)` for a reference
and no `(user_id, group_key)` for a guide (for example with `ON CONFLICT DO
NOTHING` on those unique indexes). Since L2 and L3, a user can already own
rows written with their key, and those stay as they are.

## Rollback

L1 can be reverted only until L2 ships. Its `down` raises
`ActiveRecord::IrreversibleMigration` once either table holds a row with a
`user_id`: recreating the old full unique indexes would fail, and code from
before L2 would pick an arbitrary user's row by concept and language. After
L2 has written owned rows, the rollback floor is L2's code.

The schema step's `down` makes `user_id` nullable again and recreates the
partial indexes, the schema L5 code ran against. It cannot bring back the
deleted shared rows. L5 code reads none, so rolling back to L5 loses nothing
a user sees; rolling back further, to code that still read the shared rows,
is below the floor once the schema step has run.
