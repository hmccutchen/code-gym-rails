---
paths:
  - "app/controllers/**"
  - "app/jobs/**"
  - "app/views/dashboard/**"
  - "app/views/responses/**"
  - "app/views/history/**"
  - "config/routes.rb"
  - "config/recurring.yml"
---

# Request flow


```
User logs in (address, then an emailed 6-digit code or, once it is on, an authenticator code)
  └→ enters their own Anthropic, Gemini or OpenAI API key (stored encrypted per-user;
     the key's prefix determines user.provider)
       └→ ApiKeysController#update asks that provider's list-models endpoint
          about the key first (AiService.check_key, one free GET, no retry,
          8 seconds at most; a badly shaped key never gets that far):
          a rejected key is not stored and the form says so; an accepted one
          is stored; a 403 or no answer stores it with a warning
       └→ the rejection form also offers "Save without checking": the key
          pasted again with skip_check=1 is stored with no provider call
          (AiService.skip_key_check), after the same limit and format rules
       └→ Setup lists each stored key with a Remove button; after a
          confirmation, ApiKeysController#destroy (DELETE /setup/keys/:provider)
          removes that key under the user row lock (User#remove_api_key) and
          returns to Setup. Removing the key in use switches to the most
          recently saved key that remains; removing the last one leaves no
          provider, so every page that requires a provider sends the browser
          to Setup and the hourly hand-out skips the account

Every hour (Solid Queue cron via config/recurring.yml):
  EnqueueDueGenerationsJob, the hand-out, calls no provider. For each user
  ScheduledGeneration.users holds (active, with a key, not paused, and not
  held after KeyHold::AFTER bad-key or out-of-credit
  failures in a row), at or past 8am on a weekday in their own zone
  (ScheduledGeneration.due?):
    today's set exists → SendPushReminderJob (kind: :nudge) when PushNudgePlan says so
    no set yet, and the last three sets went unopened (UnopenedSets.pause?)
                       → User#pause_for_unopened_sets!, which decides again
                         under the user row lock and pauses as "automatic";
                         nothing is enqueued, and later runs skip the paused
                         account. Not asked while
                         SchemaWait.migrations_pending?, read once per run
                         and logged as a warning when it skips
    no set yet         → GenerateDailyExercisesJob(user_id:, scheduled: true),
                         at JobPriority::SCHEDULED, so a
                         job a person is waiting on runs first
  So a later hourly run picks up a missing set only while the account is
  neither paused nor held. A held account's next set comes from a generation
  its owner starts.

GenerateDailyExercisesJob(user_id:), from the hand-out or the dashboard:
  a scheduled job first checks the user is still due (the same two
  ScheduledGeneration answers); a dashboard job skips that check
  Solid Queue discards a second click job for a user while one is queued
  or running, and likewise a second scheduled job; a click and a scheduled
  job never discard each other
  takes the user's generation claim (users.generating_since) when it starts
  running, or logs one line and stops when another generation holds it; the
  claim is released when the job ends, whatever the outcome
  stops when today's set already exists
  a scheduled job that wrote a set enqueues SendPushReminderJob (the "ready"
  reminder)
  a job that saved a set (this one or RegenerateExerciseJob) queues the
  user's missing concept write-ups (GenerateConceptReferenceJob.queue_missing,
  JobPriority::BACKGROUND, behind every scheduled set), leaving out concepts the set hides until submission
    └→ AiService.for(user) → ClaudeService | GeminiService | OpenaiService
         reads: user.recent_performance (latest qualifying assessed answers)
                user.recent_delivered_content (repetition-only notes)
         calls: the user's provider with a personalized prompt, in the user's
                chosen language (user.language_for_today)
         saves: DailyExercise { problem_set: jsonb, language } on success
         and sets users.generation_account_failures back to zero, or
         persists last_generation_error(_date) on the user on failure, raising
         that count for a bad key or no credit — the
         dashboard learns the outcome by polling GET /dashboard/status and
         reloading

User opens dashboard:
  └→ DashboardController#show
       shows today's DailyExercise, or triggers on-demand generation if missing
       (weekdays only; weekends offer a manual "generate anyway" button)
       stamps the set's opened_at the first time it is shown
       (DailyExercise#mark_opened!), never while it is still generating
       while the pause is automatic, shows one line above every state with
       Resume and "Keep it paused", both posting to
       PATCH /account/toggle_generation with return_to=dashboard
       2-4 sections, sized by the unified core-workload fold,
       unless the user fixed a count from 1 to 4 in Setup's Daily sections: the
       user's daily kinds (DailyKinds; Code Review and Design Comparison by
       default, one of them under a count of 1, plus any extra sections the
       user chose for a count of 3 or 4) are always present; Pattern of the Month, a rotating third
       (Coding Challenge / Architecture Decision / Security Review / Parsons
       Problem), and a rotating fourth (Plan Review / Ambiguity Hunt /
       Pseudocode to Code) compete for the remaining slots, which today's
       count and rotation fill. A two-section Automatic day can gain one
       optional section under the coverage exception

User interacts:
  └→ ResponsesController#create      → auto-saves answers + difficulty rating
       in one debounced fetch (idempotent). Each section's
       difficulty rating renders with that section and gates the Submit
       button — every answered
       section must be rated, and at least one must be answered; a skipped
       section owes no rating. A successful submit chains straight into #review from
       the same click — the dashboard posts the review URL #create hands back —
       which lands back on the submitted-state dashboard either way, with the
       finished review rendered in place when it completed.
  └→ ResponsesController#review      → ResponseReview → AiService#review_sections → ai_review saved,
       then redirects to the dashboard, whose submitted state renders the
       finished review in place — every exit from the action lands there, so
       the page never changes under the user based on how the review went; the
       exits that have a review to show anchor it (`#ai-review`), since the
       day's problems and answers render above it.
       Synchronous; the button disables and relabels while it runs. Fired by a
       successful submit rather than a second click; the button in
       responses/_submission is what remains for a failed or part-finished
       review. A dashboard loaded while the review claim is held shows the
       review as running and polls GET /responses/:id/review_status, then
       reloads once the claim is released or goes stale.
  └→ ResponsesController#email_review→ mails the completed review to the user,
       then returns to the dashboard (where the button lives)
  └→ DailyKindsController#update     → swaps one daily kind (DailyKindSwap): saves
       the pair under the user-row lock, writes one daily_kind_swaps row, and
       never touches today's set; the new pair starts with the next set planned.
       The reply re-renders every daily card's picker panel, so both carry the
       new version
  └→ DailyExercisesController#regenerate → replaces today's set in place (once/day),
       destroying today's response — so it is blocked once that response has been
       reviewed, the same invariant ResponsesController#start_over is blocked on
       (see "One reviewed-response invariant" in `.claude/rules/answers.md`)
  └→ HistoryController#index         → every submitted session, newest first,
       paginated 10 per page (pagy, offset) —
       the single destination for viewing any day's problems, answers, and
       review, today's included. There is no per-day review page.
       (concept tags are included in tomorrow's generation prompt)
       No review lands here any more; it is reached by navigation, by a
       post-login bounce back to a /history URL the user had already asked
       for, or by #index's own out-of-range correction. Each entry's
       problems fold by default and the newest entry's review opens, since the
       review is what someone opening the page came for.
  └→ AccountsController#show/destroy  → log out, or permanently delete the account:
       AccountDeletion removes the users row and every row that belongs to it,
       usage rows included, gives back its invite seat, and signs the browser out
  └→ AccountsController#toggle_generation → pauses as manual, or resumes, by
       the state the button posts; a resume also stamps opened_at on the
       sets that count as unopened, so the run of three starts again; a repeated pause keeps the pause time and
       makes an automatic pause manual. Returns to the Account page, or to
       the dashboard for return_to=dashboard

User browses /learn (independent of the daily flow above):
  └→ LearnController#index            → every concept in the user's vocabularies
       (their language plus the four language-independent buckets), whether or
       not they have ever been assigned one — a library, not a day's plan;
       each group shows the user's own recognition guide
       (RecognitionGuide.seen_by: their own row only)
  └→ LearnController#show              → one concept's cached reference plus its
       guide, generating either on demand when the row is missing or stale
  └→ LearnController#prepare / #prepare_ladders → queue the user's missing
       write-ups and guides at JobPriority::BACKGROUND, behind every
       scheduled set; #prepare_concept queues one write-up at click priority
       even when a press already queued that concept
  └→ GenerateConceptReferenceJob       → skips a row already written, else
       takes the user, language and concept claim (AdvisoryLock) for the
       call and the write; a job that finds the claim held calls nothing

Every dashboard, /learn and /history load, any day of the week:
  └→ FeaturedConcept.for(user)        → this user's concept for the week, from
       concepts they have met, picked on the first call of the week, a visit or
       the morning's generation, and read by every call after — rendered at the top of /learn and as a small
       callout on the dashboard, and marked on every section that carries it
```
