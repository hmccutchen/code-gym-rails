# app/javascript/controllers/fresh_day_controller.js

## What it owns

A dashboard left open in a browser tab overnight kept showing the previous
day after the 8am job wrote the new set, because only the generating panel
ever asked the server anything. This controller asks
`GET /dashboard/freshness` whether a newer set exists and reloads the page
when the reply says `stale`. `dashboard/_fresh_day` mounts it in every
dashboard state except the generating panel, whose own poll reloads.

## The server decides

The controller sends the draft scope of the set the page shows, empty when
it shows none, and acts on the reply's two booleans: `stale` says whether to
reload, and `replaced` whether to say why. It holds no copy of the rule;
that is `DailyExercise#freshness_against`, described in
`docs/code-notes/app/models/daily_exercise.md`.

The date changing is not enough to reload. A reload on a day with no set
starts on-demand generation, and it would take the form away from someone
still answering yesterday's set after midnight. Only a set that exists makes
the page stale.

## Only when a person is there, and no timer

A dashboard load stamps the set's `opened_at`, and three sets in a row left
unopened pause generation (`docs/decisions/pausing-generation.md`). A tab
that reloaded itself on a timer would stamp every morning's set with nobody
looking, and the pause would never start for someone who stopped using the
app and left a tab open.

So the controller checks only on a presence signal, each bound with
`data-action` in the partial: `visibilitychange` on the document, and
`focus`, `pageshow`, `pointermove` and `keydown` on the window. A signal
counts only while the document is visible. With no signal the tab sends
nothing, however long it stays open.

## The minimum gap

`pointermove` fires many times a second, so a check runs only when the
minimum gap has passed since the last one. The partial renders it from
`DashboardController::FRESHNESS_CHECK_GAP`. The count
starts when the controller connects, because the server rendered the page
at that moment and a check right after would learn nothing.

The gap is measured with `Date.now()`. A laptop that slept overnight has
passed the gap by the wall clock, which is the clock that matters here.

One check runs at a time: `checking` is set while a request is out, so a
slow reply cannot stack a second request behind it.

## stopped

`check` awaits a request, so a reply can land after the element has left
the page. `disconnect()` sets `stopped`, and `check` reads it after the
await, as `generating_controller.js` does. A stale reply sets it too: the
reload is on its way, and another check would add nothing.

## The reload waits for saves

The reload goes through `saveStatus.leaveWhenSaved`, so an answer save that
is pending lands first. While a save has failed, the leave stays armed and
the page reloads once that save succeeds.

## The replaced notice

A new day's set arriving overnight reloads without a word. A set
regenerated the same day, usually from another tab, would otherwise swap
the questions under the reader with no explanation, so a `replaced` reply
makes the reloaded page say "This set was replaced, so the page now shows
the current one." The sentence is `dashboard.fresh_day.replaced`, rendered
onto the element as `replacedText` because a module cannot translate.

`saveStatus.carry` takes it across the reload. It is called inside the
leave, right before `window.location.reload()`: a leave held behind a
failed save may never run, and a notice stored then would show on some
later, unrelated load of the dashboard.

It is carried under its own key, `replaced`. The answer form's saves report
and clear under `answers`, so no answer save clears the notice or writes
over it, and it behaves the same on the answer form and on the submitted
dashboard. A carried key never blocks a later leave
(`docs/code-notes/app/javascript/code_gym/save_status.md`). The banner it
appears in is the save-failure banner, so it is announced as an alert,
which is louder than this notice needs.

The controller takes the notice away itself, with `saveStatus.clear`. It
does so on the first presence signal that arrives at least
`noticeShownFor` after the controller connected; the partial renders that
from `DashboardController::REPLACED_NOTICE_SHOWN_FOR` (10 seconds). No timer
runs, as everywhere else in this controller, so the notice waits for a
reader: on a tab nobody is at, it stays. A signal counts only while the
document is visible, and the clear runs once per load.

## Two notices, one stored slot

`save_status.js` keeps one carried message in sessionStorage, and the answer
form also writes there: a save refused with `409 stale` carries "that last
change wasn't saved" under `answers` before it reloads. Both can start from
the same regeneration. The answer form's sentence wins, which is the right
one, because it tells the reader a change was lost:

- When the refused save comes back first, or while this controller is
  waiting on it, the refusal is reported under `answers`. This controller's
  leave ignores no key, so it is held and never carries. The answer form
  reloads with its own sentence.
- When this controller's leave has already run, the page is on its way out.
  A refused save that still lands writes its sentence over this one.

`spec/system/fresh_day_spec.rb` holds the first case.

## A reply that is not an answer

A failed request, or the login redirect an expired session gets, carries no
`stale: true`, so the page stays as it is and the next signal after the gap
asks again.

## The out-of-date banner (`STALE_SET_BANNER`)

`docs/decisions/a-held-set-stays-current.md` ("The out-of-date banner")
holds the decision. The partial renders `banner: true` and the banner's
fixed text as values only while `StaleSetBanner.enabled?`, and with
`bannerValue` false every path above runs as it did before.

With it on, the controller shows the banner in three cases:

- an `out_of_date` freshness reply, which never reloads by itself;
- a `stale` reply while `saveStatus.unsaved()` holds. With nothing
  unsaved, a `stale` reply reloads as described above, replaced notice and
  all;
- the `code-gym:set-not-current` window event, which `code_gym/request`
  raises for any reply whose `status` is `not_current`. The partial binds it
  with `data-action`, so the duck, autosave, submit, the critique, the note
  and the explanation need no handling of their own.

The sentence always comes from the server, in the reply or the event's
`detail.banner`, so the script holds no copy of `StaleSetNotice`. A later
sentence replaces an earlier one. Once the banner shows, `stopped` is set and
no further freshness check runs: the page has its answer, and the banner
stays until the page reloads.

### Where it sits

`dashboard/show` renders the partial right under the page header, so the
banner is near the top. The wrapper is `hidden` only while the switch is
off; with it on, the wrapper is an empty `div` and the banner inside it
carries `hidden` until it shows. It is a `.section` card with
`role="status"`. The banner is unhidden before its sentence is written, so a
screen reader sees the text change in a region already on the page.

### The unsaved line and the button label

"Unsaved" is `saveStatus.unsaved()`: `pending()`, any failure that was not
carried from an earlier page, or a `watchUnsent` probe (the duck box holding
unsent text, the explanation box holding text it was not rendered with).
`docs/code-notes/app/javascript/code_gym/save_status.md` says why those
probes are kept apart from `watch`.

While the banner shows, the controller re-reads that state every 250 ms
(`BANNER_REFRESH_MS`) on an interval and sets the second line's `hidden` and
the button's label from it. Polling was chosen over listening for events
because the inputs change in ways no event reports: a send that succeeds
empties the duck box from script, and a save's state changes inside
`save_status`. The interval starts only once the banner shows, reads only
page state and sends nothing, so it does not break "no timer" above: a tab
nobody is at still sends no request and stamps no set. It stops on
disconnect and when Reload is pressed.

A refused save keeps its failure in `failures`, so the line never drops
because a later save was refused as not current.

### Reload

The button calls `saveStatus.leaveDiscarding`, which is `leaveWhenSaved`
with every key that has failed ignored, and the same leave given as the
stranded callback. A save already in flight lands first; a failed save, or
one that fails while the button waits, never holds the reload, and after the
ten-second wait limit it reloads whatever is still pending. The person asked
for the reload, and a save refused as not current can never succeed.
