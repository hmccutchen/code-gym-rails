# Offline answer saving

The dashboard keeps answers typed during a lost
connection and sends them when it returns
(`docs/offline-answer-saving-2026-10-12.md`). `code_gym/draft_store` keeps
one copy of the unsent answers and ratings in localStorage, written on every
edit. The page restores it only when its `DailyResponse#draft_token` equals
the one the server rendered: the set's draft scope, the response id, and a
digest of the saved answers and ratings, so another day, a regenerate, a
Start over or a save from elsewhere deletes it instead, with the one exception
below. The answers queue
retries a save that got no reply on the `online` event or a 5 to 30 second
timer, never a refusal, a 5xx or the signed-out redirect. A confirmed save,
a submit, a submitted dashboard and every signed-out page clear the copy,
the last because this app runs on shared devices; a save reply or a stale refusal clears it only when
the stored copy is the one that tab sent or owns, since every tab shares it,
and the "kept on this device" wording shows only when the write succeeded. If a save reaches the server and the page reloads,
closes or is killed before its reply arrives, the copy's token is out of date,
so the copy also records the draft scope and the last few saves sent since a
confirmed reply. The page then restores the copy when the scope matches and
the answers and ratings the server rendered equal one of those saves: the
server has what the copy's later edits were typed on top of (#500). This
happens online too, whenever a reload lands in a save's round trip. It needs
the server to render back exactly what it received, so an answer the server
normalizes still loses the later edits, and since the whole payload is
compared, one such field makes every save of the session miss; the draft
store's code note (`docs/code-notes/app/javascript/code_gym/draft_store.md`) lists those cases. Every tab shares the copy, and the last
tab to edit owns all of it, its list of saves included. The stored draft
and queued save preserve explicit rating clears as JSON null. The server's
saved rating map omits cleared keys, so draft recovery compares sent rating
state with restored state after accounting for those clears.

Submit stays manual. Offline edits keep it disabled while the latest answer
or rating edit awaits server confirmation. The existing save status shows
when edits are kept on the device. Reconnection retries unanswered saves
through the same queue. The latest reply can restore readiness if the server
reports no blocker and the remaining guards allow submission.
Parsons answers are not restored, and opening the app offline still shows
the browser's offline page, since nothing caches the dashboard.

Start over changes the exercise's draft scope by advancing a server-owned
reset revision, atomically with deleting the response. Both restoration
paths therefore discard a pre-reset copy, even when one of its unconfirmed
saves matches the now-empty form. An old tab retrying after reset gets the
existing stale-save refusal and reloads. Ordinary saves, duck asks and duck
Clear leave the scope unchanged, so they do not disturb offline retries.

**Partial submission still incurs a full-day review.** The existing review
fan-out reviews every active section; an unanswered one gets an ungraded
walkthrough. It also calls the difficulty assessment. Skipping a section does
not remove its review call or the assessment. A skipped section has no grade,
so none reaches skill evidence; review scheduling and provider fan-out are
unchanged.

A submitted self-rating now describes a counted answer. This deliberately
replaces the earlier policy that retained intentional ratings on skipped
sections: the final record cannot distinguish those from ratings left behind
by clearing an answer. Historical submitted rows are not rewritten.
