# Learner notes

With learner notes turned on for an account, each day's set carries an
optional note box with one suggested question. After submission, the page
asks one more question: explain one of the day's concepts in your own words.
A saved explanation gets a short reply. One background call per set then
reads that day's duck thread, note, explanation and answers, alongside what
earlier items already said, and keeps a short list of at most five open
items: a term the engineer asked about, a possible misunderstanding, or a
concept to practise. The engineer reads, closes and deletes them on the
Account page. A later stage, not built yet, gives the next generation one
small block built from them.

The owner made these decisions on 2026-11-16, with the reply and ride-along
added on 2026-11-17 and the regeneration rule on 2026-11-18.

## Why

The duck is where questions come up while the engineer is stuck, and before
this change nothing read them. Most of those questions name no glossary term,
so matching words cannot sort them; sorting them needs a provider call. The
existing loop adapts only from submitted, graded answers
(`personalization-loop.md`). A question asked while stuck is a different
signal: it says what was unclear, where a grade says only how the answer came
out. An explanation in the engineer's own words shows a gap more directly
still.

## The two questions

Both are pure decision objects. They take values, read no record and make no
provider call. The server picks, and the page holds no copy of either rule.

**The stuck-point question** (`NoteQuestion`) is asked before submission in
the note box, at most 1,000 characters, autosaved to its own endpoint. It
picks one question from signals the app already has, first match wins: a
cleared duck thread, duck turns, a "too hard" rating, a skipped section, or
none of these. It names a section kind, never a concept, because some kinds
hide their concept until submission. The pick is stored with the note on its
first non-blank save and stays fixed, so extraction sees the question the
answer was written to. The page renders the question's key on the box and
posts it with each save, and the server stores that key when it names a real
question about one of the set's sections (`LearnerDay.shown_note_question`),
so a duck turn between the page load and the first save cannot swap the
question the note answers. Any other key falls back to the server's pick. The note is read-only once the day is submitted. A note save that reaches
the server after Submit is refused with `submitted: true`, and the page
treats that refusal as settled, so the move to the review that Submit
started is not held waiting for it.

**The explain question** (`ExplainQuestion`) is offered on every submitted day
with a usable concept tag, whether or not the engineer used the duck or rated
anything too hard. The default concept follows a duck or "too hard" signal
when there is one and is otherwise the first usable section. It steps aside
from a concept explained in the 7 days before when another option exists. A
selector lists the day's other concepts. The wording is one of three fixed
phrasings, chosen by how many times that concept was explained before. The
pick is stored with the text on the one save, and the box then locks.

## The reply, and why it is a separate call

A saved explanation gets one line on what was sound and, only when the
explanation states a misunderstanding, one line correcting it, under a
heading that says it is feedback, not a grade. It never asks for another
answer.

Three ways to build it were compared:

- **Extending the review follow-up.** The follow-up prompt sends the
  section's review text and the answer, which this reply must not read, and
  its endpoint needs a reviewed section and spends a follow-up. Using it would
  mean a new prompt and a new cap under an old name.
- **A second output of the extraction call.** Extraction may run at the end
  of the day, so the reply could arrive hours later. It would mix words meant
  for the engineer into a call meant for structured items, and a failed or
  skipped extraction would lose the reply too.
- **A separate small call** (chosen). It reads only the concept's name, the
  question's phrasing and the explanation. It answers while the engineer is
  still on the page, and a failure takes nothing else with it. Its cost is in
  the same range as the second option.

The reply is the provider's words, not the engineer's, so it is never
evidence: extraction and generation never read it.

A failed reply call is worded like every other provider failure
(`what-a-person-is-told-when-a-provider-fails.md`): `ProviderFailureText`
on its own `explanation_reply` surface, which says the feedback did not come
back and that the explanation is saved, with the failure's kind in the
reply so the page knows which it was.

## Extraction

`ExtractLearnerItemsJob` makes at most one call per set, with at most two
attempts. It waits for the explanation: an early run follows the
explanation's save, or follows the submit when the day has no explain
question, and a fallback runs at the later of local midnight and an hour
after submit. Each run takes an advisory lock on the set and re-reads, under
it, the set's ledger and the note row. The ledger (`LearnerExtraction`)
keeps text-free counts in `plan_notes["learner_extraction"]` on the day's
`DailyExercise`: the extraction attempts, the time the set closed and the
explanation reply's attempts. It is written under the exercise row lock and
merges only its own key, so generation's notes are untouched. It makes no
call, and closes the set, when learner notes are off for the account
(`LearnerNotes.on_for?`: the switch, the setting and the account's own key),
the key is held after repeated failures, or the day has no duck turn, note
or explanation. A run carries the response it was queued for, so a run
queued before Start over or a regeneration stops instead of reading the new
set. Counting its attempt and closing the set check that response again under
the ledger's locks, so a run whose set was started over after it read the
ledger leaves the replacement's ledger untouched.

**Deletion during the call holds.** The call runs outside every lock. The
merge re-checks, under the user row lock it already holds, that the set's
response is still the one read and that the note and the explanation still
hold the text the call read. It drops an item citing anything deleted
meanwhile, and writes nothing once the set was replaced. Delete all cannot
know which set a call is reading, so it stamps a text-free forgotten time on
every ledger the account has; a call whose set's stamp moved after it read
the set writes nothing, even an item citing only a duck turn (owner's
decision, 2026-11-18). In both cases the job leaves the ledger as it is,
since after Start over it belongs to the response that replaced the one
read. A note row or a set
deleted mid-call never makes the job or the reply endpoint fail: the job
logs a named outcome, and the endpoint answers with the box's current state
or the refusal text as JSON (owner's decision, 2026-11-18).

**What it reads.** Each active section through `SectionContext.render`, with
no answer key; the engineer's answer; the duck turns; the note and the
explanation; the open items without ids, leaving out any past its expiry
on the owner's local date, since the merge expires those before it compares
keys; and the labels of items closed in
the last 30 days, a few per concept. Every piece of typed text reaches the
prompt as data inside the engineer's tags, and the duck's own turns have
those tags defanged, so a duck reply cannot pass its words off as the
engineer's.

**What it never reads.** Review text, ratings, answer keys, `ConceptMastery`,
another day's text and the explanation's reply. The prompt asks for an item
only from what the engineer typed: an explicit mistaken claim is a
misconception, a stated uncertainty is a concept, and a curious question is
a term. A belief the engineer corrected later, one only the duck suggested,
an incomplete explanation and an ambiguous case yield nothing. An explanation
is not a sign of difficulty.

## The items and the merge

A label states in the third person what the engineer asked or wrote, such
as "Said an index only speeds up reads." or "Asked what eager loading
means." It never addresses the engineer ("You believe...") and never passes
a verdict ("Needs practice with..."): the engineer reads these labels on the
Account page, and a statement of what they wrote is something they can
check, where a verdict reads as a grade. The prompt asks for under 140
characters, which leaves room inside the 160-character limit the boundary
enforces, so a label that runs a little long is still kept (owner's
decision, 2026-11-18).

`LearnerItemsReply.parse` checks the reply at the boundary and writes nothing.
It drops an item with an unknown kind, a concept outside the engineer's
vocabularies, a label over one line or 160 characters, a bad term, or no
valid evidence. The server stamps every evidence reference with the set's
date and ignores any id or date in the reply.

`LearnerItem.merge!` is the one writer of new items. Under the user row lock
it expires overdue open rows, then:

1. collapses items in the reply that share a key (concept, bucket, kind and,
   for a term, the term);
2. lets an open item with the same key absorb its repeat, keeping the label
   the engineer already read and at most five references, note and
   explanation references first, so deleting that text still finds the
   item;
3. holds back a match for an item used in the last 30 days;
4. inserts the rest, at most three new a day, with `returned_after` when the
   engineer closed the same key with "I've got this";
5. displaces the open items with the oldest evidence past five.

The provider cannot close an item. An item closes when it shapes a set, when
it expires, when it is displaced, when the engineer presses "I've got this",
or when the engineer deletes it.

**Strengths are not stored.** The block may do three things: nominate a
concept, aim one problem, define a term. None of them has a use for "the
engineer is good at this". A strength could only skip a concept or raise its
level, and both change difficulty or coverage, which belong to graded
evidence through `ConceptMastery` and the rung ledger.

## Limits for the generation stage

The generation stage is not built. When it is, it takes at most one
concept-shaping item and two terms a set, and it may only nominate a concept
for a host slot that drills, retention checks and evidence-driven
reinforcement left free, aim one problem at a misunderstanding, and define
terms. It never changes difficulty: a nominated concept that mastery holds at
a reduced tier is eased at ingest as any section with that concept is, and
the notes add no easing of their own. A misunderstanding may ride along on a
section practice already assigned to that concept only when that section is
free or a normal reinforcement section; never on a retention check, an eased
section, or a section whose practice instruction carries a review gap,
because practice's own diagnosis from a graded review wins. Term definitions
go anywhere but a retention check, which tests recall without help.

## Switches and the setting

- `LEARNER_NOTES`, exactly `"1"`, on web and worker, turns on the setting, the
  note box, the explain question, the reply and extraction.
- `LEARNER_NOTES_SHAPE` will turn on the generation block. It is not read yet.
- `users.learner_notes_enabled`, off by default, turns all of it on for one
  account. It is offered only to an account on its own key, so no call spends
  a house key.

With either off, every page and prompt is as it was. Setting or unsetting
either variable is the owner's call, asked each time.

## The Account page

The Learner notes section shows while the setting is offered or the account
still has rows. It lists open items with the concept, the kind in plain
words, where each came from, the dates it came up and its expiry; a returned
item's history as plain fact; dismissed items closed in the last 30 days; and
each day's note and explanation. Delete all shows whenever the account has
any learner row, listed or not, so an expired item, one marked as got more
than 30 days ago or a used one can always be deleted; the privacy page says
what is listed and that Delete all removes everything. Every action runs
under the user row lock.
The page reads no `ConceptMastery`, no item leaves because a concept was
mastered, and its fixed copy names no tier, score or level, so nothing on it
implies a mastery tier.

## Privacy and retention

Notes and explanations are kept 365 days by their set's date, as duck threads
are. Closed items of every status are deleted 90 days after `closed_on`.
`SweepLearnerNotesJob` does both, daily. It first expires every overdue open
item, by its owner's local date, as a merge would: an account that stops
submitting runs no merge, and its open items would otherwise be kept
forever. Both tables are deleted with the
account (`deleting-an-account.md`), and a waiting fallback job, which names
the user, is discarded with it. The note, the explanation and the reply are
filtered from logs and `inspect`. While `LEARNER_NOTES` is on, the privacy
page states what is stored, the request that reads it, the reply's own
request and both periods, with every number read from `PrivacyNotice.facts`.
With the switch unset, the page is exactly as it was before learner notes,
including the list of what is stored (owner's decision, 2026-11-18).

## Deletion keeps no record

Delete removes the item and nothing remembers it. So the same item can be
written again from later evidence, a deleted used term no longer holds a new
one back, and a deleted closed item sets no `returned_after`. A record kept
to stop an item coming back would itself be a record of what the engineer
asked to have deleted.

Deleting a note or an explanation deletes every item that cited it, even
one a duck question or an answer also supports, since its label may
paraphrase the deleted text. Deleting the explanation deletes its reply. A
row left with neither a note nor an explanation is deleted outright, and
Delete all deletes every item and every note row; no empty marker row stays
behind (owner's decision, 2026-11-18). The set is still never read twice:
its ledger, on the set and not on the note row, keeps the counts that say it
was read, and deleting also discards any extraction still waiting for that
set from the queue, or every waiting one on Delete all. The ledger holds no
text, so keeping it keeps nothing the engineer asked to have deleted.

## A replaced set starts with no note

Regenerating a set or Start over deletes that day's note row, in the same
transaction as the change it makes: the note, its question and any
explanation were written about sections that no longer exist. A set can be
regenerated after submission until its review starts, so extraction may
already have read the old set. Deleting the row then works as deleting a note
on the Account page does: that date's note and explanation evidence goes, and
every item that cited them is deleted, even one with other evidence. Items
that cite only the old set's duck turns or answers stay, since they describe
what the engineer asked or wrote, which still happened. Regeneration
replaces `plan_notes` wholesale and Start over drops the ledger's key, so a
replaced set starts with fresh counts, as it starts with no note. A page still showing the replaced set gets the refresh
refusal when it saves a note or an explanation.

Regeneration changes the set's draft scope, and Start over does not, so
each save also carries the response the page was rendered for, or none. The
server refuses the save with the refresh text when that response is no
longer the set's (owner's decision, 2026-11-18). The explanation is only
offered on a submitted day, so it always names one. A note box rendered
before the first answer save names none, because that save creates the
response without telling the note box; such a note save is not checked
against the response. The answers autosave and the draft scope itself are
unchanged here (GitHub issue #821).
