# Hassan

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
- ran a layered-architecture review of `app/` and had its larger findings
  filed as issues
- checked whether the old competency-gate, Gemini status and OpenDyslexic
  issues were still worth keeping open
  **I decided:** keep all three; the gate one stays deferred with a note on
  what saved state now has to carry
- a failed or cancelled Gemini call raises a provider error and still records
  its usage `#437`
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
  **why:** models raising `AiService` errors made the domain depend on the
  provider client, found in the layered review
  **I decided:** `ProviderError` as the home, renamed everywhere with no
  aliases, and the field lists in a second PR with `LANGUAGE_PROMPTS` left
  where it is
- the rest of `AiService`'s domain data moved onto the models, closing out the
  layered review's first issue `#445`
