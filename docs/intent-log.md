# Intent log

What we worked on, day by day, tagged with the PRs it produced. One short list
a day per person.

Composed from `docs/intent/` by `compose.rb`; edit your own file there, never
this one.

## Mon Oct 19, 2026

- swap sheet spec rewritten around the new mockup `#424`
- a swap recorded against the held set it was made on `#425`
- the inline swap picker replaced with a bottom sheet `#426`
- design specs taken out of the repo `#427`
- installed the `layered-rails` and `good-readme` plugins
- profiled boot: about 0.66s warm, unused Active Storage, Action Mailbox and
  Action Text cost about 50ms
- the intent-log skill in the repo, and an entry required on every PR `#428`
  **why:** I wanted it always used for our PRs, and it only lived on my machine
  **I decided:** commit the skill to the repo rather than point CLAUDE.md at a
  personal skill
- the README as a product page for individual engineers, with the app icon
  `#429`
  **why:** I wanted it to say what the product is and who it's for
  **I decided:** it's a private product at coding-gym.pro, not an open-source
  project, so the setup and contributing sections went
- layered-architecture review of `app/`, larger findings filed as issues
- checked the three older open issues
  **I decided:** keep all three; the gate one stays deferred with a note on
  what saved state now has to carry
- an unfinished Gemini call raises and still records its usage `#437`
- the app's visible name from Code Gym to Coding Gym, to match coding-gym.pro
  `#438`
  **why:** the name people see should match the domain I'm about to show
  developers
  **I decided:** the session cookie, storage keys and code names keep the old
  name, since renaming the cookie signs everyone out; the README and
  CONTEXT.md get renamed because the repo is public; the generation prompts go
  in their own PR straight after, because rewriting the prompt snapshots is a
  generation change, and nothing that freezes a day for public viewing lands
  before it
- provider error classes moved off `AiService` into a `ProviderError` family
  `#441`
  **why:** the layered review found models depending on the provider client
  **I decided:** `ProviderError` as the home, no aliases, field lists in a
  second PR, `LANGUAGE_PROMPTS` left alone
- setup problems recorded as their own kind, not as provider failures `#444`
  **I decided:** changed my mind: record them as setup, since failing
  unrescued left pages spinning
- the rest of `AiService`'s domain data moved onto the models `#445`
- generation logging moved into `GenerationDiagnostics` `#448`
  **I decided:** diagnostics before prompts
- pseudocode prompts into `PseudocodePrompt` `#450`
- shared prompt text into `PromptStandards` `#452`

## Tue Oct 20

- the follow-up and alternate caps moved into `DailyResponse`, from the
  layered review's issue `#449`
  **I decided:** ran the critical review against what had merged since, and
  took its fixes in this PR: the review page reads the caps from the model too,
  and a spec now fails if the lock goes
- concept reference and its reframe into `ConceptReferencePrompt` `#453`
- recognition guide into `RecognitionGuidePrompt` `#454`
- section explain-differently into `ExplainDifferentlyPrompt` `#455`
- follow-ups into `FollowUpPrompt` `#457`
- an issue for the browser specs that fail on slow runs
- duck into `DuckPrompt` `#458`
- difficulty assessment into `DifficultyPrompt` `#459`
- section judge into `SectionJudgePrompt` `#460`
- review prose judge into `ReviewProseJudgePrompt` `#461`
- the two-stage review into `ReviewPrompt` `#463`
- load each area rule with its prompt classes `#464`
  **why:** Railway builds were having problems, so I asked for it stacked on
  the review PR, to merge in order once they recover
- the generation system prompt into `GenerationPrompt.system_prompt` `#466`
- landed the generation system prompt move on main, since it merged into
  its stacked base `#467`
- language wording and scenario pools into `LanguagePrompts` and
  `ScenarioPools` `#468`
- landed the domain modules move on main, since it merged into its
  stacked base too `#469`
- ladder loading into `GenerationLadders`, the first of two PRs for
  issue 431's orchestration step `#470`
  **why:** I kept drafting out of `JudgedGeneration`, since unjudged days
  draft too; each step is its own PR from main, as the issue says
- drafting into `ExerciseDraft`, the second PR for issue 431's
  orchestration step `#471`
  **why:** I had the draft carry its user and language so the retry takes
  only the draft, kind and concept

## Wed Oct 21

### Hassan

- the pseudocode critique claim onto `DailyResponse`, with a token so a
  stale caller can't clear a newer claim `#474`
- one raising `wait_for` and one 20-second wait limit for the system specs
  `#475`
  **why:** I chose that a Submit clicked while a controller is still loading
  should wait for it; the app already does, and the spec was fixed instead
- `ProfileController`'s checks and `User`'s level callbacks into a
  `ProfileUpdate` form `#476`
- call profiles and call timing off `AiService` into `CallProfiles` `#477`
  **why:** Railway builds were down, so I asked to work through the open
  enhancements without merging and merge them in order once it's back
  **I decided:** stacked branches, one per issue, each PR based on the one
  before
- each `ProviderError` class carries its own failure codes `#478`
- section-kind preference rules off `User` into `SectionKindSettings`
  `#479`
- `app/services` sorted by layer into models, prompts and clients, with
  Archspec enforcing the direction in CI `#480`
  **I decided:** the pure decisions go flat into `app/models` so no class is
  renamed, prompt classes get `app/prompts`, and Archspec is added as a gem
  with a CI step

### Hassan

- rotate every production secret after the Railway breach `#482`
  **why:** Railway reported a breach and paused builds
  **I decided:** clear the stored provider keys and have users add new ones,
  rather than re-encrypt keys that may already be exposed; build the PR now and
  merge it with the new variables once Railway is back
- looked into a small recurring cast of fictional systems that carry the
  consequences of past answers, report only
  **why:** every exercise is a fresh start today, and I want a wrong answer on
  day 12 to be the real cause of a slow page on day 40, never a flattering one
- spec for keeping the judge's blind design-comparison solves and settling
  key disagreements `#483`
  **why:** a true consequence needs a trustworthy answer key, and nobody can
  read why the judge and the key disagree, since the pick is logged and lost
  **I decided:** `both_defensible` is a call of its own, because ambiguous
  scenarios are what I most need to count; replayed and generated solves stay
  apart from live ones and never pick the fix; matched records get hand
  spot-checks, since drafter and judge are one model family and can agree
  while both wrong
  **I decided:** the fix is chosen by a rule written before the data, and I
  apply it by hand from plain counts; stage 1 merges on the OpenAI check and
  user 7's provider, and stage 2 is its own PR
- replay first against a local dump of `daily_exercises`, then production
  **why:** the real mismatch rate the night stage 1 merges, for under a
  dollar, tells me whether there's enough signal to continue

*Postponed: the recurring systems themselves, until I've read real mismatch
data.*

## Thu Oct 22

- moved production onto a fresh Railway Postgres, then deleted the old
  database and the copy job `#489`
  **I decided:** a fresh database rather than rotating the old one's password
- sign-in through Devise: a password plus an authenticator code, replacing
  the emailed code `#490`
  **why:** after the breach I wanted the security-critical parts from
  maintained libraries rather than our own code
  **I decided:** backup codes for a lost phone, open sign-up with email
  confirmation, an emailed password reset, and existing accounts enrolling at
  their next sign-in with one last emailed code
