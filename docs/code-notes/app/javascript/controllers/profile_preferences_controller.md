# app/javascript/controllers/profile_preferences_controller.js

## Independent controls

Time zone still autosaves through `PATCH /profile`, with its own error key.
Daily sections and Display keep their existing controllers and autosaves.
Track selection only previews; this includes edits made before connect.
Only explicit Apply writes the proposed track. Cancel restores the latest
server-confirmed saved selection and tells the existing value-row controller
to refresh its label; no Exercise mix values are restored.

## One preview sequence

Selection, Cancel, disconnect and delegated input/change events from mix
controls invalidate earlier previews. Before requesting one, the controller
lets sibling controllers connect, then awaits `saveStatus.settled`, including
the mix's pending 400ms edit probe. It ignores only its own `track_preview`
and `skill_level` error keys. An unrelated unsaved-setting error blocks
preview rather than being erased.

Previews use the shared request queue with their own error key on the
`exercise_mix` line. Both the queued payload and the reply check the sequence.
Obsolete callbacks cannot send a queued preview, display consequences,
report a failure or enable Apply. No second debounce interval is used.
The server renders the consequences and decides whether the track is already
saved. The browser does not calculate rung changes.

## Apply keeps the displayed confirmation

Apply captures the displayed from/to/version without replacing its version.
It starts `track_reply`, dispatches `trackSaving` to flush/freeze relevant
pending mix edits, then queues the write on the same `exercise_mix` line.
The established mix reply adoption retains newer local edits and settles
Prepare AI guidance. Selection and Cancel are disabled during the write.
Focus returns to the select when disabling/hiding the original control loses
it, but another control the user focused is left alone.

A stale Apply adopts the response's actual saved baseline, refreshes the
preview and requires another explicit Apply. It never retries the write.
An ordinary failure leaves the proposal unconfirmed with Refresh preview and
Cancel available. Refresh can recover a lost successful reply: an
already-saved preview hands its confirmed preference state through the same
`track_reply` / `trackSaved` adoption path without another write.

“Your track (...)” labels always name the last server-confirmed baseline,
including one saved in another tab. The select's value row names the proposed
choice while the preview is open. Failures use the request result's message
and remain visible; a lost reply is not described as proof nothing saved.
