# app/controllers/exercise_additions_controller.rb

Acceptance delegates to `ExerciseAdditionRequest` and maps each outcome to an
explicit HTTP result. The status endpoint only reads the current or held set,
checks the displayed scope and manifest, and returns operation state plus safe
HTML for missing cards. It does not recover expired jobs or save answers.

The status reply includes `DailyResponse#submit_blocker` alongside answered
sections. After inserting cards, the answer form may use that blocker to
restrict an already-confirmed valid form. It never uses the poll to confirm
pending local edits or to enable a previously blocked form. This keeps an
untouched tab from saving old fields merely to recompute readiness.

Original inputs and their answer keys remain outside the returned card HTML;
only newly appended cards are rendered through the usual section partial.
Ownership, draft scope and manifest checks still precede rendering.
