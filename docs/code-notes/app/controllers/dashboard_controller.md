# app/controllers/dashboard_controller.rb

## `#show`

`@featured` is set in every state the dashboard renders. `#status` does not
read the featured concept, because picking the week's concept is not
generation progress.

When generation is paused, the paused state renders the manual generate
button back in, so the user can still ask for a set.
