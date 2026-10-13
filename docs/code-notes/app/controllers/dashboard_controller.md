# app/controllers/dashboard_controller.rb

## `#show`

The featured concept is not loaded here: the view reads
`FeaturedConceptHelper#featured_concept`, once per request, so the callout
renders in every state the dashboard shows and each section's marker reads
the same pick. `#status` does not read it, because picking the week's concept
is not generation progress.

When generation is paused, the paused state renders the manual generate
button back in, so the user can still ask for a set.
