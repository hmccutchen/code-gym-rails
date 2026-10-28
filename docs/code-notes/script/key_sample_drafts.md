# `KeySampleDrafts`

Drafts sections of one keyed kind for the sampled key read between the two
stored-keys PRs, run as `script/draft_key_samples.rb KIND OUT_PATH`. The
owner is the app's only user and their days rarely hold `security_review`,
`plan_review` or `pseudocode_to_code`, so those kinds are read from drafts
(`docs/decisions/stored-answer-keys.md`, "The rarer kinds are read from
drafts").

## The path

Each draft calls `AiService#retry_section`, the route a judge rejection uses
on a real day, with one concept and one rung fixed and the kind locked at that
rung. So the generation prompt, `ProblemSetIngest`, `PlantedKey` cleaning and
the `[planted_key]` log line are the production ones. The draft is then judged
by `#judge_section` on its own route, and a prose edit is applied with
`JudgeVerdict#apply`, so the reader sees what a judged day would ship.

Rungs cycle through `KindDifficulty::LEVELS` and concepts through the kind's
selectable vocabulary at that rung, without `other`, so a sample of 6 covers
every rung and several concepts instead of six drafts of one.

A rejected draft, a draft whose key ingest dropped, and a provider or verdict
failure are counted, not kept, and another draft is made, up to
`ATTEMPTS_PER_SECTION` drafts for each section asked for.

## What it writes

The draft user is an unsaved `User`, so `DailyPlan` reads no history and the
draft lands in no day. `.service` subclasses `ClaudeService` to keep usage in
memory for the cost line instead of writing `ApiUsage` rows, and to drop
suggested concepts instead of recording them. The output file holds answer
keys, so `.check_out_path!` refuses a path inside the repository or one that
already exists, and it is deleted after the read, like the key sheet.

## The plan

Without `--run` it prints the most calls it can make and an upper bound: every
call at its output cap (`ClaudeService::MAX_TOKENS` for the retry,
`CallProfiles::JUDGE_MAX_TOKENS` for the judge) with no caching, and input
estimated at four characters a token from the real retry prompt and a judge
prompt over `FakeService`'s canned section. Real drafts write far less than the
cap, so the run's own cost line, from the reported usage, is the number to
record.
