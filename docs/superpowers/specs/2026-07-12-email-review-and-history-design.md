# Email-Me-This-Review Button + Aggregated History Page

## Context

Two read-mostly features on top of existing data:

1. An on-demand "Email me this review" button next to a completed AI review, delivering the review content to the logged-in user's own email via the existing Resend/ActionMailer/Solid Queue pipeline.
2. A `/history` page listing all of the current user's past `DailyResponse` rows, newest first, with self-rating and AI review content per entry.

No migrations are needed — both features only read existing columns (one optional column is flagged in §1 but not recommended). Explicitly out of scope: magic-link auth, Resend/SMTP config, `/test_login`, and the concept-tagging / teaching-notes / regenerate-button / multi-provider work specced on other branches.

## 0. Shared review renderer (prerequisite for both features)

**Files:** `app/views/dashboard/show.html.erb`, new `app/views/shared/_ai_review.html.erb`, `app/models/daily_response.rb`

**Finding — the current inline renderer is out of sync with the review schema.** `ClaudeService#build_review_prompt` asks Claude for, per section: `rating`, `correct`, `missed`, `better_questions`, `next_step`, `improved_code`. But `dashboard/show.html.erb:159` renders `feedback["summary"]` — a key the schema never produces — plus `improved_code`. So today's inline review shows an empty paragraph and (when present) the improved code, silently dropping the five substantive fields. Since both the history page and the email must render this same data, fixing the mapping is a prerequisite, not scope creep.

Changes:

- Define the field mapping once, as a constant on `DailyResponse`:

  ```ruby
  AI_REVIEW_FIELDS = {
    "rating"           => "Rating",
    "summary"          => "Summary",              # legacy rows only
    "correct"          => "What you got right",
    "missed"           => "What you missed",
    "better_questions" => "Questions to ask yourself",
    "next_step"        => "Next step"
  }.freeze
  ```

  `"summary"` stays in the map so any already-saved review that used that key still renders; new reviews simply never produce it. `improved_code` is deliberately not in the map — it's rendered as a code block, not a labeled paragraph, so both templates handle it separately after the loop.

- New partial `app/views/shared/_ai_review.html.erb` taking a `response:` local. Structure matches the existing markup (`.review-section` / `.review-block` / `h4` per section): for each `ai_review` section, iterate `AI_REVIEW_FIELDS`, skip blank values, render label + text; then render `improved_code` in a `pre.snippet` when present. Unknown future keys are ignored — the map is the contract.

- `dashboard/show.html.erb` replaces its inline review loop (lines 152–166) with `render "shared/ai_review", response: @response`. The `.review-*` CSS (and the `pre.snippet` rule the partial needs) moves from the dashboard `<style>` block to the layout's shared styles, since two pages now render it.

The email template does **not** render this HTML partial — it iterates the same `AI_REVIEW_FIELDS` constant in its own plain-text template (§1). One field map, two presentations; the copy (labels) lives in exactly one place.

## 1. "Email me this review" button

**Files:** `config/routes.rb`, `app/controllers/responses_controller.rb`, new `app/mailers/review_mailer.rb`, new `app/views/review_mailer/send_review.text.erb`, `app/views/dashboard/show.html.erb`

- **Route:** `post :email_review` added to the existing `resources :responses` member block, alongside `feedback` and `review`.

- **Controller:** new `ResponsesController#email_review` action (added to the `set_response` before_action list, so it's automatically scoped to `current_user.daily_responses` — no cross-user access). Guards mirror `#review`:

  ```ruby
  def email_review
    return redirect_to root_path, alert: "No review to email yet." unless @response.reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: "Review sent to #{current_user.email}."
  end
  ```

  `deliver_later` enqueues through Solid Queue (same as `UserMailer.magic_link`), so the click never blocks on Resend. Production already sets `raise_delivery_errors = true`, so a delivery failure surfaces as a failed/retried job — no extra error handling in the controller.

- **Mailer:** `ReviewMailer#send_review(daily_response)` — positional AR argument, matching the `UserMailer.magic_link(user, raw_token)` precedent (GlobalID handles serialization through `deliver_later`). Recipient is `daily_response.user.email` (the user's own address from magic-link auth — never a param). Subject: `"Your Code Gym review — #{daily_response.date.strftime('%A, %B %-d')}"`.

- **Template:** text-only (`send_review.text.erb`), matching the existing `magic_link.text.erb` precedent — no HTML-email/inline-CSS work. Body: greeting with the date, then per `ai_review` section: humanized section name, each `AI_REVIEW_FIELDS` entry as `Label: value` (blank values skipped), then `improved_code` verbatim under an "Improved code:" line when present. Same field map as the partial (§0), reformatted for plain text.

- **Button + confirmation:** in `dashboard/show.html.erb`, next to the "Claude's Review" heading (inside the `@response.reviewed?` block, adjacent to — not inside — the shared partial, so the partial stays display-only for history reuse):

  ```erb
  <%= button_to "Email me this review", email_review_response_path(@response), method: :post, class: "btn btn-ghost btn-sm" %>
  ```

  Confirmation is the flash notice (`"Review sent to …"`) after redirect to root — the existing pattern for `#review` and `#feedback`; the user stays on the dashboard with the review still visible.

- **Flagged option — `review_emailed_at` column (not recommended):** a timestamp would let the UI show "Sent ✓" persistently and dedupe repeat sends. Recommendation: skip it. The button is manual and idempotent-enough (a repeat click sends another copy of the same content — harmless), the flash already confirms the send, and skipping it keeps this feature migration-free. Add later if repeat-send noise actually happens.

## 2. Aggregated history page

**Files:** `config/routes.rb`, new `app/controllers/history_controller.rb`, new `app/views/history/index.html.erb`, `app/views/layouts/application.html.erb`

- **Route:** `get "history", to: "history#index"`.

- **Controller:** inherits `ApplicationController`, so `require_login` and `require_api_key` apply automatically. Single action:

  ```ruby
  def index
    @responses = current_user.daily_responses
                             .where.not(submitted_at: nil)
                             .includes(:daily_exercise)
                             .order(date: :desc)
  end
  ```

  Submitted-only: auto-save creates a draft row before submission, and an in-progress draft belongs on the dashboard, not in history. `includes(:daily_exercise)` avoids N+1 if the view ever needs exercise data (e.g. section titles); harmless if it doesn't.

- **Per-entry rendering** (reusing the dashboard's `.section` card styling):
  - **Date** — `response.date.strftime("%A, %B %-d, %Y")` as the entry heading.
  - **Sections answered** — derived from `answers` with the same >10-chars heuristic `completeness` uses; displayed as e.g. "2/3 sections" plus the humanized names of the answered sections. If plan time finds it cleaner, extract a small `DailyResponse#answered_sections` helper next to `completeness` so the heuristic isn't duplicated in a view.
  - **Self-rating** — `response.rating.humanize` when present ("Too easy" / "Right level" / "Too hard"), omitted when unrated.
  - **Concept tags** — guarded for the unmerged tagging branch: `if response.respond_to?(:concept_tags) && response.concept_tags.present?`, render `response.concept_tags.values.uniq.map(&:humanize)` as small labels. On current `main` the column doesn't exist, `respond_to?` is false, and the block is skipped; when `feedback-teaching-tagging` merges (jsonb map of section → concept slug, `{}` default), tags appear with no further change.
  - **AI review** — `render "shared/ai_review", response: response` (§0), wrapped in a `<details>` element (reusing the existing `details.ref` styling pattern) so a long history stays scannable; the newest entry renders with `open`, the rest collapsed. If `reviewed?` is false, show a muted "No AI review requested" line instead.

- **Pagination — none for now (flagged).** No pagination gem exists in the Gemfile, and expected volume is ~22 entries/month/user, so a full render stays reasonable for the first several months — especially with reviews collapsed behind `<details>`. When the page gets heavy, add Pagy (smallest footprint) in a follow-up; building hand-rolled offset links now is worse than either option.

- **Nav link:** add a "History" link to the logged-in `nav-links` block in `layouts/application.html.erb` (next to the user's name / logout button). The layout nav is the dashboard's nav, satisfying "link from the main dashboard" while also making history reachable from every page.

## Migrations

None. Both features read existing columns (`ai_review`, `answers`, `rating`, `submitted_at`, `date`). The only candidate migration — `review_emailed_at` — is flagged in §1 and recommended against.

## Testing

Follow existing RSpec patterns (`spec/requests`, `spec/mailers`):

- **Mailer spec** (`spec/mailers/review_mailer_spec.rb`): `send_review` addresses the response's user, subject includes the formatted date, body includes each populated `AI_REVIEW_FIELDS` label/value and the `improved_code` text, and skips blank fields.
- **Request spec — email_review** (`spec/requests/responses_spec.rb`, new file): requires login; 404s (via `set_response` scoping) for another user's response; redirects with alert when `ai_review` is absent; enqueues a `ReviewMailer` delivery job and redirects with the "Review sent to" notice when reviewed.
- **Request spec — history** (`spec/requests/history_spec.rb`): requires login; lists only `current_user`'s submitted responses, newest first; excludes unsubmitted drafts; renders review field labels for a reviewed entry and the "No AI review requested" fallback otherwise.
- **View-level regression via request spec:** the dashboard still renders review content after the partial extraction — assert a known `AI_REVIEW_FIELDS` label appears on the dashboard for a reviewed response (this also pins the §0 bug fix: `correct`/`missed` content now actually renders).

## Out of scope

- Any change to magic-link auth, Resend/SMTP config, or `/test_login`.
- Concept tagging, teaching notes, feedback UI, regenerate-button/multi-provider work (other branches/specs) — the history page only *guards* for `concept_tags`.
- HTML email styling — text-only, per the existing mailer precedent.
- Emailing reviews from the history page (button is dashboard-only for now; the partial/controller split keeps this a five-line follow-up if wanted).
