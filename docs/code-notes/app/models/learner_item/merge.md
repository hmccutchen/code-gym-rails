# app/models/learner_item/merge.rb

The rules and their order are in `docs/decisions/learner-notes.md`.

## Why the lock comes first

Every writer of `learner_items` takes the user row lock before it reads, so
two merges for the same user run one after the other and the five-item cap
holds. Overdue open rows are expired under the same lock before any key is
compared, so an expired row never absorbs a new item.

## Repeats and new items are counted apart

After the reply collapses on its keys, a repeat of an open item can only add
a day to that item, so repeats have no limit beyond one per open item. Only
new items, closed-item repeats included, count toward the three a day.

## Which five references stay

An item keeps at most five references. The note and explanation
references dated on the row's oldest evidence date always stay, at most
two, since the label was written from that day's text. Deleting that text
finds the items to delete by their references (`LearnerItem.forget_citing!`),
so a dropped one would leave the paraphrase behind. The other slots go
newest first whatever the source, so a newer duck or answer repeat is kept
and `newest_evidence_on` moves forward.

Pinning every note and explanation reference instead let five written
citations fill the cap and turn every later repeat away, and pinning by
date alone let five later notes push out the label's source. The owner
chose this middle rule on 2026-11-18, without a column naming the label's
source. Its cost: a later written citation can drop off, and deleting it
then leaves the item; and an older set's run that merges late moves the
oldest date, so the pinned day can change.

## A unique violation is a merge

The partial unique index allows one open row per key. If a row for the key
appears between the read and the insert, the insert's savepoint rolls back
and the item is absorbed into that row instead.

## Evidence deleted while the call was out

The extraction call runs outside every lock, so the engineer can delete the
note or the explanation, press Delete all or Start over, or regenerate the
set while it is out. The caller passes `still_there:`, which the merge calls
once it holds the user row lock: it answers nil when the set is no longer
the one read, and otherwise the evidence sources whose text is still the
text the call read. Every account-page deletion and Start over take the
same lock, so the answer holds until the merge commits. An item citing a
source of the set's date that is gone is not written and cannot be
absorbed, and is counted as `evidence_deleted`. When the set itself moved,
or Delete all stamped its ledger as forgotten after the call read it, the
check answers nil: the merge writes nothing, expires nothing and returns
`:replaced`, so the job leaves the ledger alone. Closing it then would
close the ledger of the response that replaced the one read. The merge never
names the note model, which keeps it inside `learner_notes_isolation_spec`;
the job builds the check.
