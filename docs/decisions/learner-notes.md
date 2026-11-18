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
answer was written to. The note is read-only once the day is submitted.

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

## Extraction

`ExtractLearnerItemsJob` makes at most one call per set, with at most two
attempts. It waits for the explanation: an early run follows the
explanation's save, or follows the submit when the day has no explain
question, and a fallback runs at the later of local midnight and an hour
after submit. Each run takes an advisory lock on the set and re-reads the
note row under it. It makes no call, and closes the set, when the switch or
the setting is off, the account has no key, the key is held after repeated
failures, or the day has no duck turn, note or explanation. A run carries the
response it was queued for, so a run queued before Start over or a
regeneration stops instead of reading the new set.

**What it reads.** Each active section through `SectionContext.render`, with
no answer key; the engineer's answer; the duck turns; the note and the
explanation; the open items without ids; and the labels of items closed in
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
   the engineer already read;
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
each day's note and explanation. Every action runs under the user row lock.
The page reads no `ConceptMastery`, no item leaves because a concept was
mastered, and its fixed copy names no tier, score or level, so nothing on it
implies a mastery tier.

## Privacy and retention

Notes and explanations are kept 365 days by their set's date, as duck threads
are. Closed items of every status are deleted 90 days after `closed_on`.
`SweepLearnerNotesJob` does both, daily. Both tables are deleted with the
account (`deleting-an-account.md`), and a waiting fallback job, which names
the user, is discarded with it. The note, the explanation and the reply are
filtered from logs and `inspect`. The privacy page states what is stored, the
request that reads it, the reply's own request and both periods, with every
number read from `PrivacyNotice.facts`.

## Deletion keeps no record

Delete removes the item and nothing remembers it. So the same item can be
written again from later evidence, a deleted used term no longer holds a new
one back, and a deleted closed item sets no `returned_after`. A record kept
to stop an item coming back would itself be a record of what the engineer
asked to have deleted.

Deleting a note or an explanation removes that date's matching evidence
references, and an item left with none is deleted too. Deleting the
explanation deletes its reply. When a set has already been read by a request,
its emptied row stays as a marker with no text, so a later run cannot read
the set a second time; otherwise the row is deleted. Delete all removes every
item and empties every note row the same way.

## A replaced set starts with no note

Regenerating a set or Start over deletes that day's note row, in the same
transaction as the change it makes: the note, its question and any
explanation were written about sections that no longer exist. A set can be
regenerated after submission until its review starts, so extraction may
already have read the old set. Deleting the row then works as deleting a note
on the Account page does: that date's note and explanation evidence goes, and
an item left with none is deleted. Items that cite only the old set's duck
turns or answers stay, since they describe what the engineer asked or wrote,
which still happened. A page still showing the replaced set gets the refresh
refusal when it saves a note or an explanation.
