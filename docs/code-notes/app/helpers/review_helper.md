# `app/helpers/review_helper.rb`

The review's labels moved here from `DailyResponse` (#582), so the model keeps the facts they read (`#answered?` and `#ai_rating_for`) and the wording lives with the views. `ReviewMailer` declares `helper ReviewHelper`, since a mailer's views do not get the app's helpers by default.

## `#review_provider_label`

Names `DailyResponse#reviewed_by` through `AiProvider.label`, so a stored `unknown` reads "AI" (#588).

## `#review_badge`

The one choice between the grade badge and the "Skipped" label, which the review partial and the email both read.

## `#review_field_label`

One source for each review field's heading, with "What a good answer covers" in place of "What you missed" on an unanswered section. `DailyResponse.ai_review_label` stays on the model, because `FollowUpPrompt` reads the graded headings in English and a prompt class cannot call a view helper.
