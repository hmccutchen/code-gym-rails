# Alternate framings of a concept reference

`ConceptReference` auto-expands
on a concept's true first exposure so a beginner has a foothold before
attempting anything — but it is one auto-generated explanation with no
fallback, and if it doesn't land there is nowhere to go. A low-weight control
*inside the disclosure* asks
`ConceptReferencesController#explain_differently` for the same concept
explained another way, capped at
`MAX_ALTERNATES_PER_CONCEPT`. The duck is deliberately not the answer to this:
`DUCK_SYSTEM_PROMPT`'s explain mode is scoped to "Describe only what is
already on their screen", which is describing a problem rather than
re-teaching a concept from zero, and that scoping is intentional.

**Nothing is persisted** — not a row, not a column. The framings live in the
tab that asked for them, exactly as the duck thread's turns do, and the cap is
the same soft, request-level kind for the same reason (each user spends their
own key). The shared `ConceptReference` row is read and never written, so one
engineer asking for another angle cannot change what a teammate reads.
Storing per user was considered and rejected as heavier than the value;
storing on the reference itself would have made the cap a race between
teammates and enlarged the cached artifact everyone reads. Accepted cost: a
framing is gone on reload, and meeting the concept again next week costs
another call.

**The safety property is the signature, not the prompt.**
`#explain_differently` has no "don't hint at the answer" rule and needs none —
it only ever runs post-review. This surface runs *before* a day is submitted,
so `AiService#explain_concept_differently(user, reference, prior_alternates:)`
is handed no exercise, no response and no section: it cannot reach today's
problem because today's problem is never passed in, the same guarantee
`#generate_concept_reference` and `#assess_difficulty` carry. A prompt line
restates it; the signature is what holds it, and a spec pins the parameter
list.

**Why not a teach-then-practice rotation** (considered, rejected): apps that
gate practice behind a lesson step do it mainly because immediate recall of
just-read material creates an illusion of competence — it feels like learning
but transfers worse than spaced, effortful retrieval. This app's model
(attempt first, reference available immediately, the concept resurfacing later
in a different framing via the mastery loop) is the better-evidenced one. The
single legitimate reason to front-load teaching — a true beginner has zero
foothold — is already covered by the first-exposure auto-expand, and
difficulty-adapts-to-experience is already live through mastery tiers and
scaffold fade. It just isn't branded as a visible "rotation", consistent with
tier state staying invisible everywhere else here.
