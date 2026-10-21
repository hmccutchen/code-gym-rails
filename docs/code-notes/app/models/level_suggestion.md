# LevelSuggestion

## Two meanings of "favourable"

`LevelSuggestion::Result#ai_favourable?` asks only whether the AI rated a
result solid or better. `ReviewedSectionResults.favourable?(…, bar:)`, which
the competency gate reads, asks for that and a favourable self-rating too.

The two rules differ because of who acts on them. The gate grows a day's
size with no one approving it, and the AI rating's calibration against the
stated level is unverified, so it waits until both ratings agree. A level
suggestion changes nothing until the person presses Apply, and the
self-rating still has its own say through the too-hard veto over the latest
three results. So the AI rating proposes alone, and the person's rating can
stop it.

The method was called `favourable?` until the rename from `TrackGraduation`.
It took a distinct name so the two rules cannot be mistaken for each other.
