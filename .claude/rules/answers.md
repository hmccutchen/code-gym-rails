---
paths:
  - "app/controllers/exercise_additions_controller.rb"
  - "app/views/exercise_additions/**"
  - "app/javascript/controllers/exercise_addition_controller.js"
  - "spec/**/*exercise_addition*"
  - "app/controllers/{responses,dashboard,daily_exercises}_controller.rb"
  - "app/controllers/concerns/current_set_lookup.rb"
  - "app/models/stale_set_notice.rb"
  - "app/models/{daily_response,daily_exercise,concept_exposure_index}.rb"
  - "app/models/exercise_section/**"
  - "app/helpers/{answer_scaffolds,section_status,self_rating}_helper.rb"
  - "app/views/responses/**"
  - "app/views/dashboard/**"
  - "app/javascript/controllers/{answer_form,parsons,comparison_answer,pseudocode_round,duck_thread,generating}_controller.js"
  - "app/javascript/code_gym/{draft_store,save_status,request}.js"
  - "app/assets/javascripts/code_gym_bootstrap.js"
  - "app/jobs/regenerate_exercise_job.rb"
  - "spec/**/*{response,dashboard,answer,submit,parsons,offline,draft,fold}*"
  - "app/models/problem_set_ingest.rb"
  - "app/views/shared/_duck_thread.html.erb"
  - "spec/**/*{daily_exercises,save_status}*"
---

# The answer form, saving and submitting

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **One "answered" authority** (`docs/decisions/one-answered-authority.md`):
  `DailyResponse.answered?` and `#answer_for` delegate to the section kind:
  prose needs any text left after scaffold labels are removed, a design
  comparison needs a pick or a reason, and Parsons needs a saved complete
  permutation. The browser holds no copy of the rule; it shows the
  `answered_sections` and `submit_blocker` from each reply. History, mastery
  and generation ask the same authority. A short answer is an answer: the old
  10-character floor was removed on 2026-10-27.
- **Answer scaffolds**: `pattern` and `architecture` ask for multi-part
  reasoning, so the generator returns an `answer_scaffold` — a short list of
  labels written for that specific question — inside the section's
  `problem_set` entry. A fresh textarea starts pre-filled with them; they are
  plain text in the same plain-string answer, so the user can delete or ignore
  them. Bounded on ingest (`ExerciseSection::MAX_SCAFFOLD_LABELS` /
  `MAX_SCAFFOLD_LABEL_LENGTH`) since it is provider output rendered into a
  form, and absent/unusable values fall back to the kind's `DEFAULT_SCAFFOLD`,
  so pre-scaffold rows render identically. `ResponsesController` normalizes on
  write: an answer that is nothing but labels stores as `""`, so reloading
  offers the scaffold again without storing its labels as the user's work.
  Other draft text remains intact; grading and read-only displays use
  `answer_for` (`docs/decisions/one-answered-authority.md`).
- **One finish action** (`docs/decisions/one-finish-action.md`): Submit is
  always clickable and the server decides via `DailyResponse#submit_blocker`;
  the browser keeps no copy of the rule. `ResponsesController#create` refuses
  a blocked submit with a 422 and saves nothing, slices ratings to
  `answered_sections` at submission, and a successful submit fires exactly one
  review from the same click. A refused or dropped submission restarts the
  draft autosave.
- **Offline answer saving** (`docs/decisions/offline-answer-saving.md`): The
  dashboard keeps unsent answers in `code_gym/draft_store` and restores them
  only when the stored `DailyResponse#draft_token` matches the rendered one,
  or when the copy's draft scope matches and the rendered answers equal one
  of the unconfirmed saves the copy lists. The last tab to edit owns the copy.
  The answers queue retries only saves that got no reply, never a refusal or
  5xx. Confirmed saves, submits, submitted dashboards and every signed-out
  page clear the copy, and submit always stays manual.
- **Folding a section** (`docs/decisions/folding-a-section.md`): Each
  section is a native `<details>` the user folds by hand. It starts open on
  the answer form and folded on the submitted dashboard, so the review is
  what that page opens on; History's sections start open inside History's
  own closed disclosure. Nothing on the form folds automatically except
  reopening a folded, rated section when its answer is edited. The summary
  holds an `<h2>` (never `role="button"`) and the status from
  `SectionStatusHelper#section_status`. Folding is purely
  visual, nothing inside a section may require visibility, and fold state is
  not persisted.
- **No free-text feedback box**: the answer form once carried an "Anything
  to adjust next time?" field whose text was quoted into the next ten days'
  generation prompts with no instruction about what to do with it. It was
  removed rather than wired up: everything someone would type there has a
  structured home — kind weights and exclusions, difficulty targets and
  locks, drills, the language setting — and scenario taste is what the
  flavor pools vary. A control that quotes text into a prompt and hopes is
  worse than no control. `ResponsesController#create` ignores a
  `feedback_text` param, `recent_performance` carries no feedback, the
  prompt renders none, and the column is gone. The review's
  self-explanation box ("Break this fix into 2-3 steps") went the same way:
  it saved text to a column nothing read, with no grading and no AI call,
  so it was a notebook dressed as a feature. Its endpoint, script, styles
  and column are removed too.
- **Idempotent saves and frozen evidence**
  (`docs/decisions/idempotent-saves-and-frozen-evidence.md`):
  `ResponsesController#create` reloads every answer save under the response
  row lock; once submitted, answers, section ratings, concept tags and
  submission time are immutable, and a stale autosave gets `submitted: true`
  with nothing changed. A repeated submit returns the existing review URL.
  Each save carries `DailyExercise#draft_scope`, and a mismatched scope gets
  `409 "stale"` and writes nothing. Start over advances the scope's reset
  revision while deleting the response under the same locks, so late saves
  cannot recreate cleared answers.
- **One reviewed-response invariant**
  (`docs/decisions/one-reviewed-response-invariant.md`): No action destroys a
  reviewed response, since `ConceptMastery.record_review!` has already moved
  mastery off it. `DailyResponse#replace_blocker` states the rule once; start
  over and regenerate refuse on it, and `RegenerateExerciseJob` re-checks it
  under `DailyExercise#with_response_locked`. A review in flight
  (`#reviewing?`) blocks too; a claim past its stale window does not.
- **A held set stays current**: the owner decided it on 2026-11-18, and on
  2026-11-19 for #829 and the regenerate guard. Two switches, each on only
  when exactly `"1"` and deleted after its trial passes: `HELD_SET_LOOKUP`
  and `STALE_SET_BANNER`. Every action an open dashboard sends finds its set
  through the one lookup, `CurrentSetLookup#current_set`
  (`User#current_exercise!`), which carries a paused user's held set forward
  only under `HELD_SET_LOOKUP`, with the move and locks unchanged. Start over
  finds its response by id, so it moves the held set only when that is the
  response's own set. Regenerate posts the page's draft scope, refuses a
  missing or mismatched one before moving anything
  (`CurrentSetLookup#shown_set_at`), moves the held set only when it is
  the shown one, and checks the scope again under the locks where it takes
  the claim (`DailyExercise#claim_regeneration!`). The pseudocode critique
  refuses a missing or mismatched scope with autosave's 409 before creating,
  claiming or sending anything, and checks it again under the locks where it
  claims (`DailyResponse#claim_pseudocode_critique!`). Finding none answers
  `errors.set_not_current` with a 404 through `#render_set_not_current`,
  switch or no switch.
  `DashboardController#freshness` only reads (`#todays_or_held_exercise`),
  so freshness never writes. Under `STALE_SET_BANNER` it adds the
  `out_of_date` answer, which never reloads the page by itself, and every
  not-current reply carries `status: "not_current"` and `banner:`, the
  sentence `StaleSetNotice` picks; with it off every reply is today's.
  `code_gym/request` turns that reply into one `code-gym:set-not-current`
  event, and `fresh_day_controller` shows the banner. The page reloads by
  itself on `stale`, from freshness or an answer save's 409, only while
  `saveStatus.unsaved()` is false. A 409 from an answer save, or from the
  note save Submit sends first, carries the freshness reply's sentence. Reload and discard changes clears the tab's draft copy first.
  Unsent duck or explanation text counts through `watchUnsent`, never
  `watch`, so it never holds a reload gate. Yesterday's unsubmitted set stays lost from
  view after a reload without a pause, by the owner's decision of
  2026-11-19: it happens only when someone works past midnight without
  pausing, and the banner says so before they reload. Detail is in
  `docs/code-notes/app/controllers/dashboard_controller.md`,
  `docs/code-notes/app/controllers/responses_controller.md`,
  `docs/code-notes/app/controllers/daily_exercises_controller.md`,
  `docs/code-notes/app/javascript/controllers/fresh_day_controller.md` and
  `docs/code-notes/app/models/user.md`.
- **Parsons input**: drag (SortableJS, CDN) is the primary reorder mechanism;
  up/down arrow buttons are injected by script only if that import fails or
  stalls for 3s. Because dragging is pointer-only, every block is focusable and
  reorderable with Ctrl+↑/↓ (bare ↑/↓ moves focus), with an `aria-live` status
  line announcing each move — that keyboard path, not the arrows, is what keeps
  the section answerable without a mouse.

Add preserves draft scope and increases the manifest revision. New submits
require both; old-tab partial autosaves remain valid. Active additions block
submit/reset/regeneration, with advisory-locked recovery before row locks.
Missing cards are inserted without replacing existing inputs. See
[On-demand additions](../../docs/decisions/on-demand-exercise-additions.md).
