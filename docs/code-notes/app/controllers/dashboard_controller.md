# app/controllers/dashboard_controller.rb

## `#show`

The featured concept is not loaded here: the view reads
`FeaturedConceptHelper#featured_concept`, once per request, so the callout
renders in every state the dashboard shows and each section's marker reads
the same pick. `#status` does not read it, because picking the week's concept
is not generation progress.

`#load_todays_set` finds the set through `User#current_exercise!` with
`carry: true`, so a dashboard load carries a held set forward whatever
`HELD_SET_LOOKUP` says, as it always has. That method re-reads today's set
outside the query cache after the move: a load that lost the race to another
tab's move used to re-read a cached nil and show the paused panel.
`#todays_exercise` is the read `#status` and `#freshness` use.

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
page sends the draft scope of the set it shows, empty when it shows none.
Today's set answers for itself: `DailyExercise#freshness_against` returns
`:current`, `:stale` or `:replaced`
(`docs/code-notes/app/models/daily_exercise.md`), and the action only looks
that name up in `FRESHNESS_REPLIES`. A day with no set answers as `:current`.
`fetch` raises on a name the table lacks, so a new outcome on the model
cannot pass through as a silent "fresh".

A day with no set is never stale: a reload then would start on-demand
generation and pull the form away from someone still working on yesterday's
set past midnight. A set behind the regeneration spinner is not stale
either, so the page reloads once, to the finished set.

`replaced` is true when the scope the page sent is an earlier write of
today's own row: the set the person was looking at was regenerated, most
likely from another tab. The reloaded page then says so. A new day's set
stays silent, since nobody expects yesterday's set to still be there. The
`shown` parameter is only ever compared with the signed-in user's own set
for today, so a made-up scope or another account's scope learns nothing: it
gets the same `stale` answer as any other value and is never `replaced`.

`#status` also treats a regenerating set as not ready and keeps its own line
for it. `#status` answers `pending` for a regenerating set even when today's
generation failed, so sharing one "finished set" reader with `#freshness`
would change which answer wins there.

`FRESHNESS_CHECK_GAP` is the shortest time between two checks from one page,
and `REPLACED_NOTICE_SHOWN_FOR` is how long the replaced notice stays before
a presence signal may take it away. Both are read only by
`dashboard/_fresh_day`, which renders them in milliseconds for the
controller; nothing on the server limits requests by them.

With `HELD_SET_LOOKUP` on, the set that answers is `User#todays_or_held_exercise`, so a held set whose scope matches the page answers `current`: the page's next real request moves it. With `STALE_SET_BANNER` on, a page that shows a set (a non-empty `shown`) when no set answers gets `FRESHNESS_REPLIES[:out_of_date]`, and every reply but `current` carries `banner:`, the sentence `StaleSetNotice` picks (`CurrentSetLookup#out_of_date_sentence`, shared with every not-current reply). With it off the replies are today's, byte for byte. `@stale_set_banner` tells `dashboard/_fresh_day` whether to render the banner's strings. `docs/decisions/a-held-set-stays-current.md` has the rules.

Like `#status`, it only reads. It does not call `mark_opened!`, enqueue a
job, or carry a paused user's held set forward; those belong to `#show`,
which the reload runs.

## `#settle_missing_set`

The plain values come from `CurrentSetLookup#missing_set_state`, which the out-of-date sentence also reads, so the banner and the reload ask `MissingSetState` the same question.

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
