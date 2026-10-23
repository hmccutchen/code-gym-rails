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
User logs in (password + authenticator code; Devise)
  └→ enters their own Anthropic, Gemini or OpenAI API key (stored encrypted per-user;
     the key's prefix determines user.provider)

8am weekdays (Solid Queue cron via config/recurring.yml):
  GenerateDailyExercisesJob
    └→ AiService.for(user) → ClaudeService | GeminiService | OpenaiService
         reads: user.recent_performance (last 10 sessions + ratings + concepts)
         calls: the user's provider with a personalized prompt, in the user's
                chosen language (user.language_for_today)
         saves: DailyExercise { problem_set: jsonb, language } on success, or
         persists last_generation_error(_date) on the user on failure — the
         dashboard learns the outcome by polling GET /dashboard/status and
         reloading (this app loads no Turbo JS, so a live push has
         no subscriber)

User opens dashboard:
  └→ DashboardController#show
       shows today's DailyExercise, or triggers on-demand generation if missing
       (weekdays only; weekends offer a manual "generate anyway" button)
       2-4 sections, sized from recent completion and the competency gate
       unless the user fixed a count in Setup's Daily sections: the user's daily
       kinds (DailyKinds; Code Review and Design Comparison by default) are
       always present; Pattern of the Month, a rotating third
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
  └→ AccountsController#show/destroy  → log out, or permanently delete (anonymize)
       the account in place while preserving all exercise/response/usage history

User browses /learn (independent of the daily flow above):
  └→ LearnController#index            → every concept in the user's vocabularies
       (their language plus the four language-independent buckets), whether or
       not they have ever been assigned one — a library, not a day's plan
  └→ LearnController#show              → one concept's cached reference plus its
       guide, generating either on demand when the row is missing or stale

Every dashboard, /learn and /history load, any day of the week:
  └→ FeaturedConcept.for(user)        → this user's concept for the week, from
       concepts they have met, picked on their first visit of the week and read
       by every visit after — rendered at the top of /learn and as a small
       callout on the dashboard, and marked on every section that carries it
```
