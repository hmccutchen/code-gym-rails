# Scenario flavor

the business setting every section's `scenario` is dressed
in comes from one prompt line, and that line offers one pool from
`AiService::SCENARIO_POOLS`: the job-adjacent `SCENARIO_DOMAINS` (webhook
delivery, rate limiting, data export) or `EVERYDAY_SCENARIO_DOMAINS` (a
shared grocery list, a gym workout log, a library checkout). `DailyPlan`
rolls which pool once per day (`SCENARIO_FLAVOR_WEIGHTS`, an even split)
and carries it on `Result#scenario_flavor`; the prompt renders the chosen
pool and the diagnostics log records the flavor. Every skill level rolls
the same weights. Nothing persists the flavor, like `code_review_mode`. A
split stated in the prompt was rejected for the reason
`CODE_REVIEW_MODE_WEIGHTS` records: nothing would decide or record it. Two
pools rather than one, because a single fixed pool goes stale and a
familiar setting starts to predict the bug.

**Everyday settings need no industry context.** Webhooks, tenants and
invoice runs assume someone already works in software, which a career
changer does not, and an everyday setting gives every level a break from
them. The everyday pool's own rule asks for plain words with no back-office
terms, and it carries no legacy GraphQL clause, the one piece of industry
framing the job-adjacent pool carries. A spec holds the pool's entries
clear of back-office words.

**A game and animation pool was removed.** It filled 70% of every
account's days, though it was meant for one person's taste.

**Flavor is setting only, never a source of concepts.** The tagged concept
and the planted issue still come from each section's own vocabulary, and
the everyday line says solving a section must never require knowing how a
company's internal systems work. That rule is the lesson of a real trial: a
`code_review` planted on frame-rate-coupled velocity, on a game-flavored
day, failed because the fix needed a domain fact (render loops are
hardware-dependent) rather than reasoning from the code, and
`ConceptReference` explains only the tagged concept, so nothing could have
supplied it. Every kind reads the same line —
`architecture`, `plan_review` and `pseudocode_to_code` have no separate
mechanism — except `ambiguity_hunt`, whose own schema fragment keeps its
scenario a Code Gym-style feature request: an unfamiliar setting would add
a second thing to work out before the ambiguity, the burden that kind exists
to remove. On a `RealSource` day `ProblemSetIngest` stamps the server's own
`scenario` over `code_review`, so that field always names the real file.
The snippet's comments, names and prose are not guaranteed: each excerpt's
`#instruction` (`RealSource::Excerpt#setting_rule`) tells the model the
flavor line does not apply and to describe Code Gym, never one of the
suggested settings or another fictional domain. That is prompt guidance, and nothing downstream checks a
snippet's wording (#171).

**Grounded sections remain eligible for retention checks.** The same
`setting_rule` gives the excerpt's source-specific instructions precedence
over the general variety, mastery-loop, and retention requests for new
domains, names, or framing (#175). The method keeps its real names; a
migration keeps its real tables and may still be a plausible next migration.
Freshness means a fresh application of the chosen concept in the planted
flaw, with concept eligibility and difficulty unchanged. Other sections
still follow the general freshness rules.

**Accepted limitation:** `RealSource.pick` prefers never-seen excerpts, then
the least recently seen, but this is not concept-specific novelty tracking.
An excerpt can recur, and `recent_performance` supplies its scenario, not
its prior planted flaw. The prompt asks for a fresh application; neither
the picker nor ingest proves it is fresh or that it measures retention.
Excluding grounded sections from retention would reduce available hosts;
requiring an unseen excerpt would need a separate eligibility policy.
Neither scheduling change is part of this fix.
