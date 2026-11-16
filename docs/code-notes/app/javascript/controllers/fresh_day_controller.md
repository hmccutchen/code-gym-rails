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
reload, and `replaced` whether to say why. It holds no copy of either rule;
they are `DailyExercise#differs_from_scope?` and `#rewritten_since_scope?`,
described in `docs/code-notes/app/controllers/dashboard_controller.md`.

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

It is carried under the `answers` key, the key the answer form's own stale
reload uses. On the answer form the next answer save that succeeds clears
it, and a failed one replaces it with the failure. The submitted dashboard
has nothing that saves under `answers`, so there the notice stays until the
next page load. A carried key never blocks a later leave
(`docs/code-notes/app/javascript/code_gym/save_status.md`). The banner it
appears in is the save-failure banner, so it is announced as an alert,
which is louder than this notice needs.

## A reply that is not an answer

A failed request, or the login redirect an expired session gets, carries no
`stale: true`, so the page stays as it is and the next signal after the gap
asks again.
