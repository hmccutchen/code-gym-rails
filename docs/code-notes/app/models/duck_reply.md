# `DuckReply`

One duck reply read under `DUCK_NARROWING`: the text the engineer is shown and
the point label parsed off it. `AiService#labelled_duck_response` builds it,
and the controller stores both.

## `.read`

Only the last line can be a label, and only when it starts with `Point:` (after
optional spaces) on a line of its own. That line is removed from the shown
text whether or not it parses, so a malformed label never reaches the page.
Any other line of its own that starts with `Point:` is removed too
(`STANDALONE_POINT_LINE`) but never becomes the point, so a label the duck
wrote too early is neither shown, stored nor passed to learner-items
extraction.
It counts as a point only when the label is two to five words. The point is
kept squished, lower-cased and without a closing full stop, so the same label
written with different spacing or case still matches.

A reply the token cap cut short gets no point, even when its last line looks
like a whole label, because the line may itself be cut. This keeps the gate
shut after a cut-off reply. Its text still gets the `…` mark, as
`#duck_response` gives it, and `cut` is true, so `DuckAnswer` can log it as
cut rather than as a reply that explained instead of asking. `cut` defaults
to false, so a reply built by hand needs only `text:` and `point:`. A reply that is nothing but its label raises
`ProviderError::InvalidResponseError`, as an empty reply does.

## `.with_point`

Writes a stored label back as the last line of a reply's text. It writes
`POINT_TAG`, the same tag `POINT_LINE` is built from, so `.read` gives back
the same text and point and the two stay one format. `DuckThread#turns_for_duck` uses
it; nothing else does.

## `.question?`

Whether a reply's text ends in `?`. `DuckThread#narrowing_due?` asks it of
stored turns, so the gate and the log use one rule.

## `.quote_outcome`

Checks the first checkable backticked quote in a narrowing reply against the
section text the duck was shown. It uses `PlantedKey::QUOTE` for the quote's
shape, `PlantedKey.checkable?` for the minimum length and `KeyQuote.normalize`
to ignore whitespace, the same rules the answer key's quote check uses. A
quote too short to check, such as `` `a` ``, is skipped and the next one is
checked; a reply with no checkable quote counts as `"none"`, since a
one-letter quote is found in almost any section. It returns `"found"`, `"missing"` or `"none"`, and nothing here holds
text for a log. `DuckAnswer` asks it only for a gate-open reply that ends in a
question; a direct explanation is logged as `narrowing=skipped` and a cut-off
reply as `narrowing=cut` instead.

## The trial

The switch stays off by default. The narrowing reply is shown whatever its
quote outcome: the duck never has the answer key, so a missed quote is a
trial failure, not a leak. The owner's stop rule turns the switch off when a
narrowing reply names the fix or the missing step, or when one follows a
dropped label. When labels drop or disagree too often, the label line is
tightened, and after two failed rounds the design goes back to the owner. A
gate that ignores labels is never the fallback, since nearly every
three-message thread has two questions in a row.
