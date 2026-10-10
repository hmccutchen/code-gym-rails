# app/views/responses/_submission.html.erb

## Purpose

The partial holds the submitted badge, the day's self-ratings, the review
trigger, the AI review and the email button. Only the dashboard's submitted
state renders it. The history page renders `responses/_answered_sections` plus
its own review disclosure, never this partial.

## Review button script

The `querySelectorAll` plus `:not([data-review-wired])` guard stops a form that
is already wired from being wired again with duplicated listeners. It was added
when Turbo re-ran this inline script on each broadcast; the layout loads no
Turbo JS now, so the guard only matters if the partial ever renders twice on
one page. The script is inline because Stimulus is not wired in this app.

`button_to`, with Rails 8's `button_to_generates_button_tag` default, renders a
`<button type="submit">` rather than an `<input type="submit">`. The two keep
their label in different properties, so the script reads and writes whichever
is present.

Disabling the button is deferred a tick, because disabling it synchronously
inside the submit handler can cancel the submission in some browsers.

Every exit from `#review` redirects to `root_path`. If the user then navigates
Back, some browsers restore the page from the back-forward cache exactly as it
was: button disabled, label swapped, `data-review-wired` already set. The
script does not run again on its own, so the button would stay dead until a
manual reload. The `pageshow` listener resets it on a cache restore.
