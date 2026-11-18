# app/controllers/account_learner_notes_controller.rb

Like the item actions, these run without `require_provider` or the
`LEARNER_NOTES` switch, since the rows stay visible and deletable either way.

Deleting a note or an explanation empties its columns and removes that date's
matching evidence from the items, deleting an item left with none. The row
itself is deleted only when no request has read its set. A row whose set an
extraction or a reply already read stays as an empty marker: its attempt
count and `extracted_at` are what stop a waiting fallback from reading the
set again and writing back the items the engineer just deleted. Delete all
does the same for every row after deleting every item.
