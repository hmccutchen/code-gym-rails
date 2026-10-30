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

- passwordless again: Devise out, the emailed code the only first factor `#491`
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
  **I decided:** the card styles load everywhere; Reminders keeps Save; cards
  clear a landscape notch
- lefthook: lint on commit, CI's checks on push `#508`
  **I decided:** system specs stay in CI
- edits typed behind a save survive a reload `#509`
  **I decided:** the copy keeps unconfirmed saves
- the Settings page as phone cards, with the Account nudges switch `#512`
  **I decided:** the nudges switch saves on change; Connection gets a "Tap Save
  to apply" tag; value rows keep the invisible select
- History scrolled sideways in the home-screen app; fixed there too

## Sat Oct 24

- the draft copy holds one tab's unconfirmed saves, never merged across tabs
  **I decided:** two tabs with identical answers may lose one unconfirmed save
- a separate agent reviews each review-comment fix before it's pushed
- a save queued behind a submit, already fixed; pinned with a spec `#521`
- find where the app has got slow and make those pages faster `#517`
  **I decided:** the work goes in its own worktree, off main, so it stays clear
  of the two branches I had open
- show a saved time zone in Settings even outside its existing choices `#522`
  **why:** Europe/London showed Detect automatically despite being a valid
  saved zone
- stop automatic push registration undoing Turn off `#523`
  **I decided:** Claude implements; the foreman does the final reviews. Each
  issue gets its own PR, Copilot review and a green-CI merge.
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
- the top nav's links to 44px at desktop widths, as foreman `#554`
  **I decided:** Claude implements and investigates; I decide the design. The
  nav gets the 1040px column on every page, its own PR after this one, and the
  doubled notch inset on landscape phones becomes its own issue
- called the phone redesign done at four PRs; the authenticator forms work fine
  for me, so no code screens
- glossary terms on the reference dropdown and every Learn page `#556`
  **why:** references use terms like partial index and sequential scan with no
  definition, and the Learn pages never ran the glossary at all
  **I decided:** wire it at render time so every existing reference gains it;
  never inside code; first occurrence per field; audit production read-only
  before writing any term list; fix the three wrong-sense entries here and
  leave the backfill, the matcher and the technique terms to the next PR; pin
  the "None" lesson rows as they render today rather than fix them
- the nav takes the page's 1040px column on every page at desktop widths `#562`

## Mon Oct 26

- glossary backfill, batch one: the audit's 47-reference terms, inflections and
  the five techniques as one-liners `#563`
  **why:** the audit showed 730 undefined terms with no glossary match, and
  "memoized" never found the memoization entry
  **I decided:** start with the 47; size a second batch from the post-deploy
  audit; no new concepts; inflections of a key match, the whole-word rule
  stands otherwise; every noun key gets its plural; one plain sentence per
  entry, fact-checked by an agent that didn't write it; a read-only export of
  the references and my last 60 days of exercise text, which I read before the
  PR leaves draft; a 480-or-fewer bar that reports, never blocks; drop eight
  forms with a second sense; track the listing tool; the tooltip question
  becomes an issue
- Progress on phone cards and the desktop layout, specced first `#565`
  **I decided:** the legend stays a disclosure at every width, with its 7 real
  entries as written; groups two across on a desktop and the full container
  width from 600px; the app wins where the boards differ; the note stays
  visible and Progress gets its own bucket class, as specced
- Learn on phone cards and the desktop layout, specced first `#567`
  **I decided:** lay out everything the page has and keep the filter's hiding
  working; reorder so this week's concept and the search come first, side by
  side on a desktop, ahead of the prepare and drills boxes
- one stylesheet per page, History, Progress and Learn first, with no visual
  change `#568`
  **why:** I don't think styling should live in the markup unless good design
  warrants it; each page should have its own modular style file
  **I decided:** refactor the three finished pages first, then build Account
  and Settings into their own sheets; a partial's styles go with the page it
  renders on, or a shared component sheet
- Account and Settings page sheets and desktop layout `#571`
  **I decided:** Account's paired cards share a height
- fuzzy Learn search `#570`
- glossary terms in alternate framings `#573`
- Today on phone cards, styles in its own sheet `#572`
  **I decided:** no sticky Submit bar: the screen felt sandwiched
- glossary_wrap always returns escaped HTML `#576`
- glossary terms throughout the review `#577`
- a repo copy of the layered review for cloud sessions `#580`
  **why:** a cloud session skipped it, having no plugins
  **I decided:** the plugin stays locally; copy only the review and the files
  it links to

## Tue Oct 27

- Today on a desktop: the answers beside a side column `#579`
  **I decided:** Submit, Generate new set and Start over in one side column,
  which ends the page on a phone; the column sticks only in a tall window;
  both regenerate buttons disabled while a submit runs
- a skipped section reviewed as a walkthrough with no grade `#581`
  **why:** an unanswered section was graded like an answer
  **I decided:** "What a good answer covers" heads its list; a short answer
  is still graded; Parsons keeps showing the correct order
- ReviewPrompt picks a section's review prompt, from the layered review
  `#584`
- a spec pinning the walkthrough prompt and the stripped grade, from the
  critical review `#586`
- the review badge and headings moved off DailyResponse into a view helper
  `#587`
- the self-rating labels and reviewing provider name moved to view helpers too
  `#589`
- a read-only baseline of how stable grading is: export my graded answers,
  regrade each five times `#590`
  **why:** I'm weighing grading by an answer's route, and wanted a
  measurement first
  **I decided:** every production export read-only, approved by me and
  deleted after; 10 sections per kind; drift reported apart from stability
- a spec for storing what code review, security review, plan review and
  pseudocode-to-code planted
  **I decided:** an unusable key keeps the section; `RUBRIC_VERSION` stays
  unless keyed grading moves ratings; a different finding counts only if at
  least as serious; I read the Ruby keys, a colleague the rest
- a closed short version of the concept in the review, on a first exposure
  or a low grade `#598`
  **I decided:** pitfalls only with an essential gap on any section sharing
  the concept; the first qualifying section offers it
- the flaky Submit nudge layout spec, fixed on its own `#591`
- I ran the baseline myself: 14 of 15 sections graded the same all five times
- two implementation plans, the short version first since it needs no keys
  `#596`
  **I decided:** every production query and billed run waits for my approval;
  one exposure count and one graded-review reader; every keyed section
  logged; keys quote in backticks
- keyed grading measured before the grader reads keys in production, from
  Copilot's review
  **why:** otherwise the competency gate and level suggestions would read
  keyed grades before the movement check

*From review: `#595`*

## Wed Oct 28

- the rarer kinds get keys as they come up; my section count stays `#600`
- a change review kind: the flaw in how a 2–3 file change interacts `#601`
  **I decided:** its own kind at every rung, scaled in files and visibility;
  changed lines highlighted; a failed key refuses it; JavaScript gets data
  modeling, Knex and a looser quote match; after the reviews, its grader
  waits on key gating with its own fixture, its first appearance
  is accepted, and the judge never rejects on rung fit
- answer keys stored for four kinds, read by nothing yet `#602`
  **why:** the grader guesses the plant, so a wrong guess looks like a miss
  **I decided:** measure the extra tokens from usage rows after deploy; after
  the reviews, whitespace-blind quotes, a separate cleaning step, and a stop
  rule on drafts of quoting kinds
- code review's snippet capped at 40 shown lines, refused not cut `#603`
- the rarer kinds' keys read from drafts, not my days `#606`
  **why:** I'm the only user; adding them to my days would fake progress
  **I decided:** a colleague reads them; a kind without a reader stays off;
  every billed run waits for my approval
- the script that drafts them, plan-only until I approve `#607`
  **I decided:** local only, writing no row; after the reviews, only the three
  drafted kinds
- a judged retry refused at ingest no longer costs a second retry `#609`
  **I decided:** a refused retry spends one retry and continues; other
  failures still drop; the retry prompt stays, left to its own issue
- the nav counts a landscape notch once, aligning the brand at 932px `#614`
  **I decided:** only the double count; the offset below 900px is its own
  issue
- the nav menu clears a landscape notch; Today joins the top nav `#616`
  **I decided:** Today rides this fix, on its tab's route
- a judged retry told why its section was turned down, when recorded `#617`
  **why:** every retry heard "rejected on wording alone"
  **I decided:** a reason only when recorded; one fixed line per principle
  or boundary check, a snapshot each; otherwise "write a new section for the
  same concept"; never the draft or the judge's words; a report of what
  each retry path records
- the grader starts with code review, gated on its read and token cost;
  drafted kinds join later `#611 open`

## Thu Oct 29

- a security_review snippet that is missing or past 40 lines refused at
  ingest `#619`
  **why:** its prompt asks for about 10 to 15 lines, but nothing checked the
  reply, so a snippet of any length, or none, shipped
  **I decided:** share code_review's 40-line cap rather than a tighter one
  of its own, since nothing measures what providers return; after the
  reviews, share only the usable-text test across the three kinds, each
  kind keeping its own refusals
- a concept's Learn page shows its explanation, guide and pitfalls again
  when its stored lesson is the string "None" `#620`
  **why:** four production references stored "None", which counted as a
  lesson, so their pages hid everything but the tagline, code and senior
  lens, and offered no way to write a lesson
  **I decided:** after an explanation of each option with a real example,
  both a read-side guard, so a stored value with nothing to show counts as
  no lesson, and a one-time migration clearing every lesson that isn't an
  object
- the nav lined up with the page column from 800 to 899px `#621`
  **why:** below 900px the nav ran full width while the page stopped at
  800px, so the brand sat up to 50px left of the content
  **I decided:** after a probe showed no link overflowing at any text size,
  cap the nav at the page column less the side insets, so it lines up with
  a landscape notch too
- code review can show 2–3 files at higher rungs, built with its weight at 0
  `#622`
  **why:** a code review shouldn't need its own kind to show a change across
  files
  **I decided:** a shape of code review, not a new kind; junior 1 file,
  mid-level 2, senior and principal 2–3; half of non-RealSource days once on;
  after the reviews, the judge line waits for launch B, the key checks the
  files now, and KeyQuote's whole-file search waits for its caller
- a multi-file code review's check made safe to run twice, keeping the
  provider's quoted lines beside the line numbers they resolve to
  `#624`
  **why:** the check overwrote the quotes with line numbers, so a second
  run would refuse a good section
  **I decided:** keep the two in separate fields rather than accept
  numbers as already resolved, so a provider can never skip the quote
  match by sending numbers

## Fri Oct 30

- a blind-solve triage for drafted code review keys added to the plan:
  about 30 drafts solved without their keys, compared in Ruby `#611 open`
  **why:** to find the keys worth reading first
  **I decided:** agreement only screens, and the real-day read stays the
  gate; I approve each run's call count and cost first; the disagreements
  and three agreements go to a key sheet outside the repo
- the section judge shown a multi-file code review's marked line numbers,
  not the provider's quotes `#629 merged`
  **why:** a quote that matched no line marks nothing on the page, so the
  judge could read a change the engineer never sees, and nothing pinned
  what the judge sees for files
  **I decided:** numbers only, hidden through a per-kind hook rather than a
  branch in the judge prompt
