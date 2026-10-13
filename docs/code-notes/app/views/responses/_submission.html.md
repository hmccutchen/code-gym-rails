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

## A review still running

While `DailyResponse#reviewing?` is true, the partial shows a disabled
"Generating review…" button in place of the review button, and
`responses/_review_in_progress` in place of the failure sentence. That state
is reached when someone returns to the dashboard while their review request
is still running on the server: the review is a full form POST, and Puma
keeps running a request after the browser goes away (#376). Before this, the
page showed the ordinary review button, and a click came back with the
"already being generated" alert.

The partial polls `GET /responses/:id/review_status`, which answers `pending`
while the claim is held and `ready` once it is released or stale, and reloads
on `ready`. The reload then shows whatever the server has: the review, a
partial review with its failure sentence, or the button. An earlier failure
sentence stays hidden while a retry runs, since it describes an attempt that
is being replaced.

A request killed by a deploy leaves its claim in place with nothing written.
The page then shows the review as running until the claim goes stale after
`DailyResponse::REVIEW_CLAIM_STALE_AFTER` (12 minutes), and the reload after
that offers the button again. Nothing on the server can tell a killed request
from a slow one before then, and the claim is what stops a second review
from starting while the first may still be running, so the page shows the
same state the server enforces. The poll's attempt budget covers that whole
window, so the reload arrives without the user having to act.
