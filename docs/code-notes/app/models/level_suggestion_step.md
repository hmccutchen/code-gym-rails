# LevelSuggestionStep

One move a level suggestion showed: a kind, the rung it was shown at
(`from`) and the rung offered (`to`). The dashboard card and Setup post the
steps they displayed with an Apply or a dismissal, and this class is the
boundary check on that input. `parse_all` returns nil for anything that is
not a non-empty list of one-rung moves along `LevelSuggestion::LADDER` for
known kinds, each kind once, and the endpoints answer 422 for nil.

The shape check cannot tell whether a step is still true. That is the
caller's job under the user-row lock: `from` has to equal the kind's stored
rung, or the request is stale and gets a 409. That check is what stops a
card left open in one tab from moving a kind after the skill level changed
in another tab, since a skill-level change does not bump
`section_kind_preferences_version`.

A client can still post a true one-rung step it was never shown. The worst
that does is label its own event row `suggestion`; the move itself is one
the user could make in Setup.
