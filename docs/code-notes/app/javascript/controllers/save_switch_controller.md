# app/javascript/controllers/save_switch_controller.js

## What it owns

A checkbox that saves the moment it changes. Its first user is the "Suggest
level changes" checkbox at the top of Setup's Exercise mix, shown to every
account, which saves `users.level_suggestions` through `PATCH /profile`. That
switch is kept apart from the Exercise mix controller because that controller
owns the versioned preference save, and this setting bumps no
`section_kind_preferences_version`, so mixing them would change the mix's 409
handling. The controller was `level_suggestions_switch_controller.js` until it
was generalized so Account's reminder nudges switch could share it (#507).

## Values

| Value | Meaning | Level suggestions | Nudges |
|---|---|---|---|
| `url` | where to PATCH | `profile_path` | `push_subscription_path` |
| `key` | the `CodeGymSaveStatus` key | `"level_suggestions"` | `"nudges"` |
| `field` | the body's key | `"level_suggestions"` | `"nudges"` |
| `scope` | optional wrapper key | `"user"` | none |
| `focus` | optional | set by the server when the card's link is followed | none |
| `savedText` | optional, the status line's text | none | `t("switches.saved")` |

The body is `{ [scope]: { [field]: checked } }` with a scope, or
`{ [field]: checked }` without one.

## The status line

The optional `status` target is a `p.switch-status[role=status]` rendered
empty under the switch row. `toggle()` clears it when a change starts and sets
it to `savedText` once a save succeeds with nothing else queued under the key,
so two quick taps say Saved once, after the second. A failed save leaves it
empty and the banner reports the failure. The text comes from the server, so
the script holds no copy.

## The checkbox is reverted, not optimistic

A checkbox shows its new state the moment it is clicked, before anything is
saved. If the save fails the control is lying, so the controller keeps
`saved` as the last state the server confirmed and writes it back once
nothing is still queued under that key. The queued check is what keeps a
fast second click from being reverted by the first click's reply.

## An edit made before the modules load

`saved` seeds from `defaultChecked`, not `checked`: the box may already have
been clicked while the deferred modules were loading, and seeding from its
current state would record an unsaved change as saved and then silently keep
it. When the two differ, `connect()` sends the save the missing listener
would have sent. The Exercise mix scans only its own rows and difficulty
controls for such early edits, so this box never triggers a mix save.

## Arriving from the card

The dashboard card links to `/setup?show=level_suggestions#level-suggestions`.
The server decides what that means: it renders the mix open and sets this
controller's `focus` value. The controller only acts on it, scrolling the
switch to the middle of the screen and moving focus to the checkbox, the
control the link was about. Instant scrolling, the browser's default, needs
no reduced-motion handling.
