# app/views/responses/_submission.html.erb

## Purpose

The partial holds the submitted badge, the day's self-ratings, the review
trigger, the AI review and the email button. Only the dashboard's submitted
state renders it. The history page renders `responses/_answered_sections` plus
its own review disclosure, never this partial.

## Review button controller

`data-controller="review-button"` on the review form drives the button;
`docs/code-notes/app/javascript/controllers/review_button_controller.md` covers
the deferred disable, the bfcache reset, and why the wiring guard and the
button-versus-input branch the inline script carried are both gone.

Every exit from `#review` redirects to `root_path`. If the user then navigates
Back, some browsers restore the page from the back-forward cache exactly as it
was, button disabled and label swapped, which is what the controller's
`pageshow` listener resets.
