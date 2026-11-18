# app/controllers/account_learner_notes_controller.rb

Like the item actions, these run without `require_provider` or the
`LEARNER_NOTES` switch, since the rows stay visible and deletable either way.

Deleting a note or an explanation empties its columns and deletes every
item that cited it, even one that a duck question or an answer also
supports, since its label may paraphrase the deleted text. A row left with
neither is deleted outright, as Delete all deletes every row and item (the
owner's decision of 2026-11-18). No empty marker stays behind: whether the
set was read, and how many extraction and reply attempts it had, are kept
on the set (`LearnerExtraction`), so a waiting fallback still finds the set
already read.

After a deletion the action also discards any extraction job still waiting
for that set, or for every set on Delete all, through
`ExtractLearnerItemsJob.discard_waiting`. A run already under way is not
stopped; the merge's check under the user row lock drops whatever it read
that is gone.
