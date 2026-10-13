# Offline answer saving (2026-10-12)

The dashboard keeps answers typed during a lost connection and sends them
when it returns. Three pieces do it, and each is small on purpose.

## What changed

1. **A copy on the device.** `code_gym/draft_store` keeps the unsent answers
   and ratings in localStorage, written on every edit and restored on the next
   dashboard load. It is restored only when the server's saved answers are
   still the ones the copy started from.
2. **Retry when no reply came.** The answers queue retries a save whose fetch
   rejected, on the browser's `online` event or a 5 to 30 second timer. A 4xx,
   a 5xx and the signed-out redirect got a reply, so they are final. The
   banner says the answers are kept on this device and will save when the
   connection returns.
3. **Submit offline.** Submit stays manual. Without a connection the banner
   says the answers were not submitted and are kept on the device, Submit stays
   enabled, and the message clears when the connection returns.

The server also refuses a save written for a different set (the draft scope,
in its own commit), because a retry can now arrive after midnight or after a
regenerate.

## The draft token

The server renders `DailyResponse#draft_token` on the page and returns it in
every save reply: the set's draft scope (exercise id and `generated_at`), the
response id or `new`, and a digest of the saved answers and ratings. A copy is
restored only when its token equals the rendered one. A new day, a regenerate,
a Start over, or a save from another tab or device each changes the token, so
the copy is deleted rather than restored over newer work. A digest rather than
`updated_at`, because a pseudocode round writes the same row and would
otherwise discard a good copy.

**A lost reply costs the edits after it.** If a save reaches the server but
its reply is lost, and the page is killed before a retry, the copy's token no
longer matches. The copy is dropped and the server's draft shows. That draft
includes the save that got through, so the loss is limited to edits made after
that save.

## Accepted limits

- Opening the app while still offline shows the browser's offline page,
  because the dashboard is `no-store` and the service worker caches nothing.
  The copy is restored on the next online load.
- Two tabs on the same day share one copy, and the last edit wins, the same
  rule the server applies to full-payload saves.
- Parsons answers are not restored. Each move saves at once, and restoring
  would mean reordering the rendered blocks.
- Text from yesterday that never reached the server is discarded once the day
  changes, since today's set refuses it.
- Every signed-out page deletes the copy, for shared devices. A session that
  expires with unsent text loses that text.
- A submitted dashboard deletes the copy too. The day is frozen once
  submitted, so a copy left by a tab that never heard the submit could never
  be saved.
- 5xx replies are not retried, so a deploy's brief 502 or 503 shows the
  generic failure. The copy still holds the text, and the next edit or reload
  sends it.

## Out of scope

Caching the dashboard in the service worker, and queueing Submit. A submit
saves the answers and returns the review URL, and the page then posts that URL
as a separate request that starts the billed review; queueing either while
offline would fire them later, out of the user's sight. A review
the server is still running shows as a plain "Get AI review" button on
return; that is #376.
