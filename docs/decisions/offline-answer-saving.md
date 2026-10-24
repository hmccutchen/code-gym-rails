# Offline answer saving

the dashboard keeps answers typed during a lost
connection and sends them when it returns
(`docs/offline-answer-saving-2026-10-12.md`). `code_gym/draft_store` keeps
one copy of the unsent answers and ratings in localStorage, written on every
edit. The page restores it only when its `DailyResponse#draft_token` equals
the one the server rendered: the set's draft scope, the response id, and a
digest of the saved answers and ratings, so another day, a regenerate, a
Start over or a save from elsewhere deletes it instead. The answers queue
retries a save that got no reply on the `online` event or a 5 to 30 second
timer, never a refusal, a 5xx or the signed-out redirect. A confirmed save,
a submit, a submitted dashboard and every signed-out page clear the copy,
the last because this app runs on shared devices; a save reply or a stale refusal clears it only when
the stored copy is the one that tab sent or owns, since every tab shares it,
and the "kept on this device" wording shows only when the write succeeded. If a save reaches the server and the page reloads,
closes or is killed before its reply arrives, the copy's token is out of date,
so the copy also records what the save on the wire sent and the draft scope.
The page then restores the copy when the scope matches and the answers and
ratings the server rendered are exactly that save: the server has what the
copy's later edits were typed on top of, so nothing is lost (#500). This
happens online too, whenever a reload lands in a save's round trip. Submit stays manual: offline, it
says the answers were not submitted and are kept, and stays enabled.
Parsons answers are not restored, and opening the app offline still shows
the browser's offline page, since nothing caches the dashboard.

**Partial submission still incurs a full-day review.** The existing review
fan-out grades every active section, including skipped ones, and also calls
the difficulty assessment. Skipping a section does not remove its grading
call or the assessment. Skipped grades stay outside skill evidence; review
scheduling and provider fan-out are unchanged.

A submitted self-rating now describes a counted answer. This deliberately
replaces the earlier policy that retained intentional ratings on skipped
sections: the final record cannot distinguish those from ratings left behind
by clearing an answer. Historical submitted rows are not rewritten.
