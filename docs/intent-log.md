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
  name, since renaming the cookie signs everyone out; the README and CONTEXT.md
  get renamed because the repo is public; the generation prompts go in their
  own PR straight after, because rewriting the prompt snapshots is a generation
  change, and nothing that freezes a day for public viewing lands before it
- provider error classes moved off `AiService` into a `ProviderError` family
  `#441`
  **why:** the layered review found models depending on the provider client
  **I decided:** `ProviderError` as the home, no aliases, field lists in a
  second PR, `LANGUAGE_PROMPTS` left alone
- setup problems recorded as their own kind, not as provider failures `#444`
  **I decided:** changed my mind: record them as setup, since failing unrescued
  left pages spinning
- the rest of `AiService`'s domain data moved onto the models `#445`
- generation logging moved into `GenerationDiagnostics` `#448`
  **I decided:** diagnostics before prompts
- pseudocode prompts into `PseudocodePrompt` `#450`
- shared prompt text into `PromptStandards` `#452`

## Tue Oct 20

- the follow-up and alternate caps moved into `DailyResponse`, from the layered
  review's issue `#449`
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
- landed the generation system prompt move on main, since it merged into its
  stacked base `#467`
- language wording and scenario pools into `LanguagePrompts` and
  `ScenarioPools` `#468`
- landed the domain modules move on main, since it merged into its stacked base
  too `#469`
- ladder loading into `GenerationLadders`, the first of two PRs for issue 431's
  orchestration step `#470`
  **why:** I kept drafting out of `JudgedGeneration`, since unjudged days draft
  too; each step is its own PR from main, as the issue says
- drafting into `ExerciseDraft`, the second PR for issue 431's orchestration
  step `#471`
  **why:** I had the draft carry its user and language so the retry takes only
  the draft, kind and concept

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
- spec for keeping the judge's blind design-comparison solves and settling key
  disagreements `#483`
  **why:** a true consequence needs a trustworthy answer key, and nobody can
  read why the judge and the key disagree, since the pick is logged and lost
  **I decided:** `both_defensible` is a call of its own, because ambiguous
  scenarios are what I most need to count; replayed and generated solves stay
  apart from live ones and never pick the fix; matched records get hand
  spot-checks, since drafter and judge are one model family and can agree while
  both wrong
  **I decided:** the fix is chosen by a rule written before the data, and I
  apply it by hand from plain counts; stage 1 merges on the OpenAI check and
  user 7's provider, and stage 2 is its own PR
- replay first against a local dump of `daily_exercises`, then production
  **why:** the real mismatch rate the night stage 1 merges, for under a dollar,
  tells me whether there's enough signal to continue
- stage 1: a table and model to keep the judge's blind solves `#484`
- stage 1: send OpenAI the judge's reply schema, with a tool to measure it
  `#485`
- stage 1: record each live blind judge solve with the set `#486`
- stage 1: a script that replays every stored design comparison through the
  judge `#487`
- stage 1: an admin page to read the judge solves and make the calls `#488`

*Postponed: the recurring systems themselves, until I've read real mismatch
data.*

## Thu Oct 22

- moved production onto a fresh Railway Postgres, then deleted the old database
  and the copy job `#489`
  **I decided:** a fresh database rather than rotating the old one's password
- sign-in through Devise: a password plus an authenticator code, replacing the
  emailed code `#490`
  **why:** after the breach I wanted the security-critical parts from
  maintained libraries rather than our own code
  **I decided:** backup codes for a lost phone, open sign-up with email
  confirmation, an emailed password reset, and existing accounts enrolling at
  their next sign-in with one last emailed code

## Fri Oct 23

- passwordless again: Devise out, the emailed code the only first factor
  `#491`
  **why:** no password column ever, and an optional authenticator app later
  **I decided:** sign-up unchanged; Devise columns dropped in the same PR; a
  10-minute code; trusted proxies split out, required before I post publicly
- from my layered review: the login code off the job queue; one signed-in
  lookup
- an optional authenticator app as a second sign-in factor `#493`
  **why:** the inbox alone protects an account today
  **I decided:** a daily cap of 20 wrong codes, counted on the user row;
  no-store on pages with the key or codes; turning it on or off ends every
  other session; a phone check before and after merge
- from review: each session gets its own setup key
  **I decided:** the key stays in the session until a code verifies; the model
  takes session values; spec and plan docs dropped; extraction is an issue
- two reviews per PR, critical and layered, each by its own agent `#492`
  **I decided:** a fresh agent checks findings before any change
- the test rules say CI runs on Postgres 18
- stop a double tap posting the sign-in forms twice `#495`
  **why:** every emailed code said it was wrong, and the home-screen app ended
  on a 404
  **I decided:** Turn on and New recovery codes start disabled; the server
  accepts a repeat of a sign-in it just completed
- each API call's cost on its usage row, Anthropic keys only `#472`
  **I decided:** Gemini and OpenAI costs stay null; prices stay on the
  providers; a timeout costs null
- the Account usage card in dollars `#497`
- the authenticator in place of the emailed code `#496`, onto main `#502`
  **I decided:** a double-tapped address gets its challenge back for 30 seconds
- a flaky system spec `#499`
- the Account page as phone cards, second of five redesign PRs `#504`
  **I decided:** the card styles load everywhere; Reminders keeps Save;
  cards clear a landscape notch
- lefthook: lint on commit, CI's checks on push `#508`
  **I decided:** system specs stay in CI
- edits typed behind a save survive a reload `#509`
  **I decided:** the copy keeps unconfirmed saves
- the Settings page as phone cards, with the Account nudges switch `#512`
  **I decided:** the nudges switch saves on change; Connection gets a "Tap
  Save to apply" tag; value rows keep the invisible select
- History scrolled sideways in the home-screen app; fixed there too

## Sat Oct 24

- the draft copy holds one tab's unconfirmed saves, never merged across tabs
  **I decided:** two tabs with identical answers may lose one unconfirmed save
- a separate agent reviews each review-comment fix before it's pushed
- a save queued behind a submit, already fixed; pinned with a spec `#521`
- find where the app has got slow and make those pages faster `#517`
  **I decided:** the work goes in its own worktree, off main, so it stays
  clear of the two branches I had open
- show a saved time zone in Settings even outside its existing choices `#522`
  **why:** Europe/London showed Detect automatically despite being a valid
  saved zone
- stop automatic push registration undoing Turn off `#523`
  **I decided:** Claude implements; the foreman does the final reviews.
  Each issue gets its own PR, Copilot review and a green-CI merge.
- share the VAPID test credentials across request, job and system specs `#525`
- share the draft key and settled-save waits across system specs `#529`
- keep Account styles with the partials that render them `#530`
- keep pending-trial session access in a controller concern `#531`
- move authenticator rules off User `#534`
- move concept exposure reads into their own model `#535`
- make push-disabled tests ignore exported VAPID values `#536`
- move draft-copy bookkeeping out of the answer-form controller `#537`
- share fetch stubs across system specs `#538`
- keep Settings styles with the partials that render them `#539`
- preserve exported push credentials after service specs `#540`
- keep controller sessions out of models `#541`
- keep authenticator deletion fields with the authenticator `#542`
- read the pull-refresh test key from its production owner `#543`
- speed up Progress's history reads `#544`
- Exercise mix controls sized for a phone, fourth redesign PR `#545`
  **why:** the skip and lock boxes and the difficulty radios were desktop-sized
  inside the new card
  **I decided:** the switch reads "Skip this kind" and on still means skipped;
  difficulty stays real radios, one 48px row each, so the controllers don't
  change; the explanation says Skip too; the request bodies are pinned before
  and after; the two Settings rules the page can't hold live in the layout
- phone and desktop layouts for all six pages, from the design boards
  **I decided:** the app wins where a board disagrees; desktop from 900px in a
  1040px column; 44px targets everywhere; one PR per page, History first

## Sun Oct 25

- PR 4 built task by task, a fresh agent per task and a reviewer after each
- the Exercise mix note says "turn Skip off" beside the Skip switch `#547`
  **why:** "turn it back on" read as turning the skip on
  **I decided:** fix it from main after the Exercise mix PR merged, not inside
  it; "turn Skip off" over "stop skipping it"
- build the desktop foundation and History from the spec `#549`
  **I decided:** the spec rides in the PR for review and comes out after the
  critical review, before the merge
- the swap picker says "skip" and "turn Skip off" for a skipped kind `#552`
  **I decided:** its own PR, separate from the desktop work
