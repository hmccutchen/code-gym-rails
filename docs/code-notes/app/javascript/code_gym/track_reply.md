# `code_gym/track_reply`

Holds the last successful track save's reply until the Exercise mix claims it.

Setup's track select and the Exercise mix are separate Stimulus controllers,
and importmap loads each controller module on its own, so either can connect
first. The track select hands its reply to the mix through the
`profile-preferences:trackSaved` event, but a mix whose module is still loading
has no listener yet: it would connect showing the targets the server rendered
and post the version the track change moved past, and its next save would
409. So `profile_preferences` also records the reply here, and the mix `take`s
it in `connect` and adopts it as if the event had reached it.

`take` clears the reply, and the mix also takes it when the event does reach
it, so a reply is adopted once. A reply kept after that would be older than
the mix's own later saves, and adopting it on a later connect would roll the
form and version back.

The value is per page load: the module is a singleton for the document, and
this app's layout loads no Turbo, so a navigation starts it empty.
