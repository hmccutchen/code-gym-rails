# app/controllers/dashboard_controller.rb

## `#show`

The featured concept is not loaded here: the view reads
`FeaturedConceptHelper#featured_concept`, once per request, so the callout
renders in every state the dashboard shows and each section's marker reads
the same pick. `#status` does not read it, because picking the week's concept
is not generation progress.

`#load_todays_set` gives the stored response `current_user` as its user, so the review's
short version reads the exposure index the page already built for the
signed-in user instead of loading the user again and building a second one.

When generation is paused, the paused state renders the manual generate
button back in, so the user can still ask for a set.

## `#settle_missing_set`

`MissingSetState` decides what a day with no set shows, and its order is the
rule: an ended trial first, then a missing provider, a fresh manual trigger
(the `flash[:generating]` that `DailyExercisesController` sets), today's
failure, the weekend, and the pause. The controller only reads the user and
the clock into plain values, enqueues `GenerateDailyExercisesJob` when the
state is `:start_generation` and shows that as `:generating`. A regenerating
set shows `:generating` too, before any of that runs, so the view reads
`@content_state` for what the content area shows. No request reaches
`:awaiting_provider`: `ApplicationController#require_provider` lets through
only a user who is `provider_ready?` or `trial?`, and a keyless trial that
isn't active is `trial_ended?`, which comes first. The view has no branch for
it, so a change that makes it reachable needs one.
