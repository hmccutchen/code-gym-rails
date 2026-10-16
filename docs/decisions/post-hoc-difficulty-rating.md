# Post-hoc difficulty rating

once a section is reviewed, its review block
also shows how hard the PROBLEM was — `straightforward` / `moderate` /
`demanding` (`DailyResponse::DIFFICULTY_LEVELS`) plus a one-sentence reason —
so a rough grade can read as "this was legitimately hard" rather than as
unexplained struggle. Three levels in problem-describing words, deliberately
disjoint from the 4-level AI grade badge it renders under (a spec holds the
vocabularies disjoint), because two same-shaped ratings side by side would be
read as one axis. **It must never become a second readout of
`ConceptMastery`'s tier**, which the mastery design keeps invisible precisely
so it cannot shape engagement — so it is assessed at review time by
`AiService#assess_difficulty`, which is handed *no* `daily_response` and none
of the user's history. The signature is the guarantee: it cannot see the
answers, the self-ratings, the grade it runs beside, or the tier, because
none of them are passed to it. Generation-time was rejected for exactly this
reason — the generator has just been told "for any concept marked
`(reduced)` … ease the difficulty only", so a self-assessment there grades
the instruction it was given; folding it into the grading call was rejected
because that call's shared context carries every answer and self-rating, and
a rating drawn from those launders performance (and so, indirectly, tier)
into "difficulty". Its per-section material comes from
`AiService#duck_section_context`, already the single authority for "the
section as the engineer sees it", so it inherits that method's answer-key
exclusion rather than restating it. Cost is one extra provider call per
review *attempt* (not per section), billed as `assess_difficulty` and capped
by `AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS` — which is sized from the
largest valid reply plus an allowance for the model overrunning the
requested length, and, by being passed at all, is what turns off the
extended thinking `ClaudeService` would otherwise leave on. It runs as one
more thread in the existing fan-out, and once grading finishes it gets only
`DIFFICULTY_ASSESSMENT_GRACE_SECONDS` to land before the review goes out
without it — so the note can add at most that grace period to a request,
never the provider's whole retry budget; a thread abandoned that way still
records its `ApiUsage` row, which is honest accounting for a call the
provider already billed. Any failure in it is swallowed — `StandardError`
wide, not just `AiService::Error`, because `Thread#value` re-raises past
`ResponseReview#call`'s rescues, and a note must never cost the
engineer the review itself. Stored at
`ai_review[section]["difficulty"]` — no migration, and no pre-answer surface
can reach it even in principle, since `ai_review` does not exist until a
*submitted* response is reviewed. Display-only: nothing about tier
transitions, retention scheduling, or generation guidance changed.
