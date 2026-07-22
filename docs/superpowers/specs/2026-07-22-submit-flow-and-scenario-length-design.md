# Submit-flow consolidation + shorter architecture scenarios

Date: 2026-07-22

Two independent changes, specced together because they land in one branch.
Change 1 is routing and view logic. Change 2 is prompt text. **Neither requires
a migration** — `daily_responses.rating` and `.feedback_text` already exist.

---

## Change 1 — Simplify the post-submit flow

### Problem

Submitting redirects to `responses#show`, a page that presents four things at
once: the problems, the answers, a difficulty-rating widget, and a "Get review"
button. Nothing sequences them, so finishing a day's work feels like four
disconnected chores rather than one flow. The rating in particular is stranded
*after* submission, where it reads as an afterthought.

### Current implementation

| Piece | Location | Behavior |
| --- | --- | --- |
| Rating widget | `app/views/responses/_feedback_form.html.erb` | Own `form_with` → `PATCH /responses/:id/feedback`, full-page redirect back to `responses#show`. Rendered `:prominent` when reviewed, `:quiet` otherwise. |
| Submitted state | `app/views/responses/_submission.html.erb` | Submitted badge, review button (only when `!reviewed?`), the review, "Email me this review", then the feedback form. |
| Review page | `app/views/responses/show.html.erb` | Renders exactly `responses/_answered_sections` + `responses/_submission` — nothing else. |
| Dashboard submitted branch | `app/views/dashboard/_exercise.html.erb:19-21` | Renders those same two partials. |
| Submit | `_exercise.html.erb:143-177` | `fetch` POST to `responses#create`, then `window.location = data.redirect`. |
| Review call | `responses_controller.rb:72` | `AiService#review_response` — **fully synchronous**, inline, then redirect. |
| History | `history/index.html.erb` | Date, meta pills, collapsible AI review. Never shows problems or answers. |

**`responses#show` is pure duplication.** It composes the same two partials the
dashboard already composes. Nothing links to it — no nav entry, no mailer link,
no Turbo Stream target. It is reachable only via redirects from `create`,
`feedback`, `review`, and `email_review`, all of which this change retargets.
**Nothing built since depends on it; retiring it conflicts with nothing.**

### Target flow

```
Problem set (3 sections)
  └→ rating widget at the end, above the Submit button
       └→ clicking a rating autosaves it silently and reveals Submit
  └→ Submit answers  (hidden until rated)
       └→ back to the dashboard, submitted state
            └→ [ Request AI review ]   (manual, never auto-triggered)
                 └→ button disables, label → "Generating review…"
                      └→ redirect to /history#response-<id>, today's entry open
```

### Decisions

**1. Rating moves to the end of the problem set.** Rendered inside `gym-form`
in `dashboard/_exercise.html.erb`, immediately above `.submit-row`. Not gated on
`submitted?` or `reviewed?` — it is part of finishing the day's work.

**2. Rating folds into `ResponsesController#create`.** The rating buttons become
`type="button"` elements carrying `data-rating`; clicking one toggles `.active`
and fires the *existing* autosave `fetch` with the rating in the payload. The
optional notes textarea joins the same debounced autosave. `response_params`
gains `:rating, :feedback_text`.

Assignment must not clobber on partial payloads — the autosave sends whatever
the form currently holds, so assign only when the key is present:

```ruby
@response.assign_attributes(
  answers:      submitted_answers.presence || @response.answers,
  submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at,
  concept_tags: exercise_concept_tags(exercise)
)
@response.rating        = response_params[:rating]        if response_params.key?(:rating)
@response.feedback_text = response_params[:feedback_text] if response_params.key?(:feedback_text)
```

**3. Rating is required to submit.** The submit row renders with
`style="display:none"` when `response.rating` is blank, and the inline script
reveals it the moment a rating is clicked. A draft that already carries a rating
renders with Submit visible on load.

Hidden, not disabled — a disabled-but-visible button is a dead end the user has
to guess their way out of; an absent one directs attention to the rating row,
which is the only thing standing in the way.

**No server-side "missing rating" rejection.** The client cannot submit without
a rating, and the only path around it is a hand-crafted request. Adding a
validation would mean an error branch that no real user can reach. Deliberate
omission, recorded here so it doesn't read as an oversight later.

Post-submit, the rating is no longer editable — it becomes a read-only pill
("Rated: Just right") in `_submission.html.erb`'s submit row, next to the
✓ Submitted badge, matching how history already displays it. The rating was
answered as part of the day's work; re-opening it after submission is what this
change is removing.

**4. `PATCH /responses/:id/feedback` retires entirely** — route, controller
action, and `_feedback_form.html.erb`. Its only caller was that partial.
`feedback_params` is deleted. `spec/requests/dashboard_spec.rb:123-129`
("round-trips rating and feedback text through the feedback action") moves to
the `responses#create` request spec.

**5. `responses#show` retires** — route (`resources :responses, only: [:create]`),
action, and `show.html.erb`. `_answered_sections.html.erb` and
`_submission.html.erb` survive; they keep serving the dashboard and now also
history. Their header comments, which name `responses#show`, get updated.

**6. History becomes the single destination for any day's response + review.**
Each entry gains a collapsed `<details>` "Problems & answers" block rendering
the existing `responses/_answered_sections` partial — the same rendering the
dashboard uses, not a fork. Today's entry auto-opens (both the problems block
and the review block, matching the existing `i.zero?` behavior).

```
History

▼ Wednesday, July 22, 2026          ← today, auto-open
  [3/3 sections] [Rated: Just right] [n_plus_one]
  ▼ Problems & answers
     1 — Code Review   … snippet … your answer
     2 — Pattern       … your answer
     3 — Architecture  … your answer
  ▼ Claude's review

▶ Tuesday, July 21, 2026
  [2/3 sections] [Rated: Too hard]
  ▶ Problems & answers
  ▶ Claude's review
```

Each entry wrapper gets `id="response-<id>"` so it can be anchored.
`HistoryController#index` adds `daily_exercise` to its `includes` —
`_answered_sections` reads `exercise.code_review` etc., so without it the page
N+1s once per entry.

**7. Redirect targets.**

| Action | Was | Becomes |
| --- | --- | --- |
| `create` (submit, JSON) | `redirect: response_path` | `redirect: root_path` |
| `create` (submit, HTML) | `response_path` | `root_path` |
| `create` (autosave) | no redirect key | unchanged |
| `review` success | `response_path` | `history_path(anchor: "response-#{@response.id}")` |
| `review` guard/error paths | `response_path` | `root_path` — the user came from the dashboard and the retry button lives there |
| `email_review` | `response_path` | `history_path(anchor: "response-#{@response.id}")` — the button is rendered on history, so this returns the user where they were |
| `feedback` | `response_path` | action deleted |

The anchor approach is straightforward: a plain fragment on an element that
already needs an `id` for nothing else. No scroll JS.

`email_review`'s button lives in `_submission.html.erb`, which now renders in
two places (dashboard submitted state, history entry). Redirecting to history
from the dashboard is a mild relocation, but it lands on the review the user
just mailed themselves — acceptable, and it keeps one target rather than
branching on referrer.

**8. Loading state — inline script, no Turbo Streams.** `review_response` is
synchronous (`responses_controller.rb:72`), so the request simply takes as long
as the provider takes. The review `button_to` gets `form: { data: { turbo: false } }`
and an id; a small inline `<script>` in `_submission.html.erb` disables the
input and swaps its value to "Generating review…" on submit, matching the
`gym-form` convention already in `_exercise.html.erb:150-151`. Per project
memory, Stimulus is not wired in this app — inline scripts are the convention.

### Files touched

```
app/controllers/responses_controller.rb   create/review/email_review retarget; feedback + show deleted
app/controllers/history_controller.rb     includes(:daily_exercise)
config/routes.rb                           drop :show and the feedback member route
app/views/dashboard/_exercise.html.erb     rating widget + hidden submit row + script
app/views/responses/_submission.html.erb   drop feedback_form renders; add review loading script
app/views/responses/_feedback_form.html.erb  DELETED
app/views/responses/show.html.erb            DELETED
app/views/history/index.html.erb           per-entry id + collapsible answered_sections
app/views/responses/_answered_sections.html.erb  header comment only
app/views/dashboard/show.html.erb          .feedback-quiet/.feedback-prominent CSS → rating-row styles for the form context
```

### Test plan

Update `spec/requests/responses_spec.rb`:
- Delete the entire `GET /responses/:id (review page)` block (~lines 315-397).
- Retarget the three redirect assertions (~lines 400-427) to `root_path`.
- Retarget `review` and `email_review` redirect assertions to
  `history_path(anchor: ...)`.
- Add: rating + feedback_text round-trip through `POST /responses` (JSON and
  native), covering both the autosave payload and the final-submit payload.
- Add: an autosave payload omitting `rating` does not clear an existing rating.

Update `spec/requests/dashboard_spec.rb`:
- Move the feedback round-trip test to the responses spec.
- Add: the submit row is hidden when the draft has no rating, visible when it does.
- Add: the rating widget renders in the unsubmitted problem-set view.

Add to `spec/requests/history_spec.rb`:
- A submitted entry renders its problems and answers.
- Today's entry renders open; older entries render closed.

Verification is not complete until the flow is driven in Chrome —
rate → submit → request review → land on history — per project convention that
browser-verifiable UI is checked in the browser, not only in specs.

---

## Change 2 — Shorten architecture scenarios

### Problem

Generated scenarios stack five-plus constraints into one paragraph before the
question appears: scale figure, symptom, technical detail, team/infra context,
and a business/budget constraint. The reader spends their attention parsing
setup rather than reasoning about the decision.

The cause is literal. Two places in `app/services/ai_service.rb` enumerate the
constraint categories as a checklist, and neither caps length:

- **`exercise_schema_for`, line 197** —
  `"scenario": "string — realistic production scenario with real constraints (team size, scale, reliability needs, existing tech debt)"`
- **`build_exercise_prompt`, line 284** —
  `"Give a realistic production scenario with concrete constraints (team size, scale, reliability needs, existing tech debt), present 2-3 viable options…"`

Four named categories, twice, read as four things to include. The model complies.

### Fix

**`exercise_schema_for` (line 197):**

```
"scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
"question":  "string — ONE sentence asking for a decision + justification",
```

**`build_exercise_prompt` third_guidance (line 284):**

```
- The third section is an ARCHITECTURE decision, not a coding task. Present 2-3 viable options and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
- Keep the architecture scenario SHORT: 2-3 sentences, ~50 words maximum, and exactly 2-3 concrete constraints total. Usually the observable symptom plus one hard technical constraint is enough — pick only the constraints the decision actually turns on, and leave the rest out. Do NOT stack scale figures, team size, infrastructure detail, budget, and timeline into one scenario.
- Short does not mean vague: name real numbers and real systems for the 2-3 constraints you do include. Fewer constraints, not fuzzier ones.
- The architecture question itself is one sentence — do not restate the scenario in it.
```

The `~50 words max` mirrors the existing `~10-15 lines` guidance on `snippet`
(line 227) — an explicit cap in the same style, not left to the model.

The question field is capped too. It currently reads
`"string — asks for a decision + justification"` with no length bound, which is
exactly the gap that let the scenario grow; closing one without the other just
moves the sprawl.

### Before / after

**Before** (real output, ~90 words, 5 constraints):

> Your healthcare appointment scheduling platform has grown to 200K
> appointments/month. The operations team needs a real-time analytics dashboard
> showing appointment volume, no-show rates, provider utilization, and patient
> wait times — refreshed every 30 seconds. These queries scan large date ranges
> and multiple joins… Your team has 3 engineers, you're on AWS RDS Postgres
> (currently a single instance), and the business requires <200ms API response
> times… Budget allows for infrastructure changes but not a full data warehouse
> migration this quarter.

**After, example A** — concept `caching_strategy`, 2 sentences, 2 constraints
(symptom + staleness tolerance):

> Your appointment analytics dashboard runs a four-way join over 200K rows and
> takes 2.5 seconds to load. Product needs it under 300ms, and the numbers can
> be up to a minute stale.

**After, example B** — concept `scaling_bottlenecks`, 2 sentences, 2 constraints
(symptom + hard external limit):

> A nightly job re-syncs 80K inventory records and now overruns into business
> hours. The vendor's API caps you at 10 requests/second and has no bulk
> endpoint.

Both keep real numbers and a real system. What's gone is team size, cloud
provider, budget, and timeline — none of which the caching or batching decision
actually turns on.

### Files touched

`app/services/ai_service.rb` only — prompt text, two locations. No schema
change, no parsing change, no migration.

### Test plan

`spec/services/ai_service_spec.rb` asserts the new instructions appear in the
built prompt (the existing specs already assert on prompt content, so this
follows the established pattern). Prompt quality itself is verified by
generating a real set against a live key and reading the output — assertions
can confirm the instruction is present, not that the model obeyed it.

---

## Explicitly unchanged

Magic-link auth, Resend/SMTP, `ConceptReference`'s always-visible display,
concept tagging, `teaching_note`, timezone handling, the language-preference
spec, `ARCHITECTURE_CONCEPTS`, the mastery loop
(`self_rating_favorable? && ai_rating_favorable?`), and the review/evaluation
criteria for architecture answers.

Review stays manual and on-demand. Nothing in Change 1 auto-triggers it.

**No migrations in either change.**
