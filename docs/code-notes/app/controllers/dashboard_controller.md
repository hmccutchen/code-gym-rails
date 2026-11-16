# app/controllers/dashboard_controller.rb

## `#show`

The featured concept is not loaded here: the view reads
`FeaturedConceptHelper#featured_concept`, once per request, so the callout
renders in every state the dashboard shows and each section's marker reads
the same pick. `#status` does not read it, because picking the week's concept
is not generation progress.

`#todays_exercise` is the one read of today's set, and it is not memoized:
`#load_todays_set` calls it again after `carry_held_set_forward!`, because a
second first-load of the day can lose the race and move nothing.

`#load_todays_set` gives the stored response `current_user` as its user, so the review's
short version reads the exposure index the page already built for the
signed-in user instead of loading the user again and building a second one.

When generation is paused, the paused state renders the manual generate
button back in, so the user can still ask for a set.

`opened_at` is also written when generation resumes
(`docs/decisions/pausing-generation.md`, "Resume ends the run"); this action
is the write that means the set was shown.

`#show` calls `DailyExercise#mark_opened!` on the set it is about to render,
after the regenerating check has returned, so a set behind the spinner is
not stamped. The write is one guarded `UPDATE` on a GET, with no read back:
when another request stamped the set first, this copy holds its own time in
memory, a moment later than the stored one, and nothing on the page reads it. It records that the
page was shown, which is the fact the pause rule needs, and `#load_todays_set`
already writes on this action when it carries a held set forward.

## `#freshness`

An open dashboard asks this whether to reload
(`docs/code-notes/app/javascript/controllers/fresh_day_controller.md`). The
page sends the draft scope of the set it shows, empty when it shows none,
and `DailyExercise#differs_from_scope?` compares it with today's set. The
answer is stale only when today's set exists, is not being regenerated and
has another scope. The regeneration check is here and not on the model,
because it is about what the page does next: the generating panel the reload
would land on has its own poll. A day with no set is never stale: a reload then would
start on-demand generation and pull the form away from someone still
working on yesterday's set past midnight. A set behind the regeneration
spinner is not stale either, so the page reloads once, to the finished set.

The reply also carries `replaced`, true when the page is stale and the scope
it sent is an earlier write of today's own row
(`DailyExercise#rewritten_since_scope?`): the set the person was looking at
was regenerated, most likely from another tab. The reloaded page then says
so. A new day's set stays silent, since nobody expects yesterday's set to
still be there. The `shown` parameter is only ever compared with the
signed-in user's own set for today, so a made-up scope or another account's
scope learns nothing: it gets the same `stale` answer as any other value and
is never `replaced`.

`#status` also treats a regenerating set as not ready, and the two actions
keep their own line for it. `#status` answers `pending` for a regenerating
set even when today's generation failed, so folding both into one "finished
set" reader would change which answer wins there.

`FRESHNESS_CHECK_GAP` is the shortest time between two checks from one page.
`dashboard/_fresh_day` renders it in milliseconds for the controller.

Like `#status`, it only reads. It does not call `mark_opened!`, enqueue a
job, or carry a paused user's held set forward; those belong to `#show`,
which the reload runs.

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
