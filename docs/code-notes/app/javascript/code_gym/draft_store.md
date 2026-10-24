# app/javascript/code_gym/draft_store.js

## Purpose

Keeps one copy of the dashboard's unsent answers on the device, so text typed
while the connection was down survives the page being closed or killed. The
answer form writes it on every edit, restores it on the next load, and clears
it once the server has the same answers. Design and tradeoffs:
`docs/offline-answer-saving-2026-10-12.md`.

The module owns the copy whole: the key, the stored shape
`{token, scope, sent, answers, ratings}`, and every rule for when it is
restored, rewritten or cleared. Its default export, `DraftCopy`, is what the
answer form holds, one per connection. It takes plain data, the answers and
ratings as `{answers, ratings}`, and never reads the page; the answer form's
code note says which page values it hands over.

## localStorage, one key

localStorage, because iOS drops a home-screen app's sessionStorage when the
app is killed, and a killed app is the case this exists for. One key, because
only one day's form is ever open: a copy from any other day or set fails the
restore check and is deleted on the next dashboard load. Within the same set,
a copy whose save landed without a reply is restored too; see below.

System specs read the key from the `const KEY = "..."` line
(`JavascriptReadyHelper.draft_key_in`), and the suite refuses to load if that
line changes shape, so a rename or restyle of it updates the helper too.

## Cleared on every signed-out page

The app runs on shared devices. Logging out lands on the login page, and the
layout marks every signed-out page with `data-signed-out-page` on `<body>`, so this
module deletes the copy there. That also covers a session that expired: the
copy is gone, and with it any text that never reached the server.

## Cleared on a submitted dashboard

A submitted day takes no more saves, so a copy left behind by another tab, or
by a tab that never heard its own submit's reply, can never be sent. The
submitted dashboard has no answer form to clear it, so it renders a
`data-submitted-day` marker and this module deletes the copy when it finds one.

## Every access is wrapped

Private browsing, a full quota or blocked site data can make localStorage
throw. The page then works as it did before this module existed. `DraftCopy`'s
`kept` says whether its last write stored the copy, so the answer form
promises the answers are kept on this device only when they are.

## The token, and who owns the copy

Every edit writes the answers and ratings (`store`) with the draft token the
copy was built on (the one the server rendered, or the one the last ok save
reply carried, adopted in `settle`), the draft scope, and this tab's
unconfirmed saves. All tabs share one copy, and the last tab to edit owns it:
an edit replaces the whole copy, its list included, so a copy is always one
tab's complete view.

On connect, `restorable()` returns the stored copy when its token equals the
page's token, meaning the server's saved answers are still exactly the ones
the copy started from, or in the one case described below, when a save landed
but its reply didn't. Anything else (another day, a regenerated set, a Start
over, or a save from another tab or device that isn't in the copy's list)
deletes it. The token is a digest of the saved answers and ratings, not
`updated_at`, because a pseudocode round writes the same row without touching
the answers.

## Settling a save

`settle()` runs on an ok save reply. It clears the copy when the reply is for
exactly the answers on screen, comparing answers and ratings with their keys
sorted (`canonicalDraft`), like the server's digest, since two tabs can insert
the same ratings in different orders. Otherwise it tells the caller the
screen moved on, and the caller rewrites the copy on the reply's token, so
later edits stay kept. A submit, a stale refusal and a reload into the
submitted page all clear it too.

## Saves whose reply never arrived

When a save reaches the server but its reply never arrives, because the page
reloaded, closed or was killed in between, the next load renders a token the
copy does not have. That happens online too, whenever a reload lands in a
save's round trip, and the edits typed behind that save are the ones at risk.
So the copy also holds the draft scope and `sent`: what each save sent since
the last confirmed reply, as `canonicalDraft` strings. `recordSend()` adds one
on every attempt, retries included, since a retry carries newer text and
either attempt may be the one that landed. It keeps the five most recent
(`UNCONFIRMED_SAVES_KEPT`), so a long run of retries can't fill localStorage;
an older one that landed falls back to the old loss. An attempt, unlike an
edit, writes only that list, through `recordUnconfirmedSaves()`, and only into
a copy with this tab's token and scope and exactly the answers it sends;
otherwise a retry from a stale tab would overwrite a newer copy another tab
wrote meanwhile. Only an ok reply clears the list (`settle()`), so a refused
save's payload stays in it. That is harmless, since the page can only render
it if the server already holds it.

The list only ever holds the saves of the tab whose answers the copy holds.
Nothing merges two tabs' lists: each merge rule tried here let one tab's
answers be restored over a save another tab had committed. The cost is that
two tabs showing identical answers can lose one tab's unconfirmed save, as
before. A restored copy hands its list on (`takeOverUnconfirmedSaves()`), so
a save still on the wire through one reload stays in the list for the next.
The answer form skips that hand-over when the restore kept an edit typed
before it connected; its code note says why.

`rendersUnconfirmedSave()` then lets `restorable()` return a copy whose token
is out of date when its scope is the page's and the answers and ratings the
server rendered equal one of those saves. The server holds that save, so the
copy's later edits go back on top of it. Any other mismatch still deletes the
copy. The scope check keeps another day's copy out even when both days'
answers happen to match. Start over keeps the scope, so a copy survives it
only when one of its saves equals the blank or scaffold page the server
renders after it.

The page decides this itself, by comparing what it sent with what the server
rendered, rather than the server deciding. It works only when the server
renders back exactly what it received. The comparison covers the whole
payload, every section and rating, so one field that doesn't round-trip
makes every save of the session miss, and the edits behind it fall back to
the old loss, however many other sections round-trip. These answers don't:

- text `UserText.normalize` changes: NFC normalization, or stripped
  zero-width, bidi, tag and control characters
- an answer starting with a newline, which `_textarea.html.erb`'s markup
  drops on render
- a whitespace-only or non-substantive answer, stored as `""`
- an answer over the server's 12,000-character clamp

A save id the server stores and renders back would remove these misses. It
needs a column, so it waits until a lost edit with pasted text turns up.

## Clearing only this tab's copy

Every dashboard tab shares the one key, so a tab clears the copy only when the
stored copy is the one it owns or sent: `settle()` when the stored answers are
the ones that save sent, and `clearOwn()`, on a stale refusal, when the stored
copy carries this tab's token. An old tab therefore cannot delete what a newer
one wrote. `discard()` clears it whoever wrote it, for a finished day.
