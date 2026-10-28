# `app/helpers/review_helper.rb`

The review's labels moved here from `DailyResponse` (#582), so the model keeps the facts they read (`#answered?` and `#ai_rating_for`) and the wording lives with the views. `ReviewMailer` declares `helper ReviewHelper`, since a mailer's views do not get the app's helpers by default.

## `#review_badge`

The one choice between the grade badge and the "Skipped" label, which the review partial and the email both read.

## `#review_field_label`

One source for each review field's heading, with "What a good answer covers" in place of "What you missed" on an unanswered section. `DailyResponse.ai_review_label` stays on the model, because `FollowUpPrompt` reads the graded headings in English and a prompt class cannot call a view helper.

## `#review_short_version`

Returns what the review partial renders for the concept's short version (the
reference row, its bucket and whether pitfalls show), or nil. The rules stay
in `ReviewShortVersion`; the helper builds one per response for the page,
keyed by the record's identity, and looks the row up with the key the model
decided on, through `concept_reference_for`, which memoizes per request. It
reads `response.user.concept_exposures`, so a caller that has the signed-in
user should hand the response that same instance; `DashboardController#show`
does, and History's `includes(:user)` does through `inverse_of`.

`learn_link` is false when the bucket is outside
`ConceptBucket.slice_for(response.user.language)`, the same check
`LearnScope#validated_bucket` makes, so a past day in a language the user
has since switched away from shows the block without a link that would 404.
