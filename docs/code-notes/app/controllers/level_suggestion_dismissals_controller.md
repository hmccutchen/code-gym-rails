# app/controllers/level_suggestion_dismissals_controller.rb

## Why a refused write is a JSON 422

The event rows this endpoint writes cannot be invalid: every kind is checked
against `ExerciseSection.keys` before the write, the action comes from
`ACTIONS_BY_REASON`, and a dismissal row carries no source. A spec builds one
for every kind and reason to hold that.

The user row can be invalid. `update!` runs every unconditional `User`
validation, so a stored value outside a list, such as the legacy
`developing` skill level an old process could once write, makes it raise
`ActiveRecord::RecordInvalid`. Rails would answer that with its HTML error
page and a 422, which `code_gym/request.js` cannot read as the app's own
error. `locked_record_cutoffs` rescues it outside `with_lock`, so the
transaction has already rolled back the event rows, logs the error class
only, and answers with the card's own "Those sections can't be set aside."
An unloadable time zone never gets this far, since every action runs in the
user's zone and that fails first.
