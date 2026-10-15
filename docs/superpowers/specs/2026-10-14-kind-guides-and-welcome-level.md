# Kind guides and a welcome level step — plan (revision 2)

## Changes since revision 1

1. **Copy checked against prompts.** I checked every summary against its kind's generation prompt, schema and answer form (list in §3).
   - Fixed challenge: the starter code is optional.
   - Fixed pattern: the section names the pattern; the engineer doesn't name it.
   - Fixed ambiguity hunt: "what you'd need clarified" instead of "list the questions".
   - Fixed plan review: the plan is written as if by an AI assistant, not a teammate.
   - Fixed design comparison: the deciding fact can be in the question as well as the scenario.
   - Fixed Parsons: it reorders blocks, and Command works as well as Ctrl.
2. **"planted" removed** from Code Review. None of the other nine used it. I also dropped "spec" from the ambiguity hunt example.
3. **Example domains:**
   - gym: 3 (pattern, Parsons, plan review)
   - grocery or shopping: 3 (design comparison, challenge, security review)
   - library: 2 (code review, architecture)
   - Code Gym's own features: 1 (ambiguity hunt, which that kind requires)
   - room bookings: 1 (pseudocode)
4. **Answer-form disclosure** now shows only until the person has answered that kind on a submitted day, worked out from `section_ratings` with no new column. Setup always shows it. Design, tests and snapshot notes are updated.
5. **Setup skill-level hint:** it is deferred because its mismatch remains until PR 2, which owns the rewrite, not because it is accurate.
6. **New note:** PR 2 must drop its Experienced-hint rewrite (decision E). Non-track accounts get no suggestions or step-backs until PR 2.
7. **Ambiguity-hunt gap categories** are not constants. They are inline prompt text. This is now a reviewer check, not a spec.
8. **Decisions 1-7 are recorded as made.** New decisions are 8 and 9.

## Context

New accounts see ten section kinds with only a name. Only `sections.<key>.name` and an answer placeholder exist (`config/locales/en.yml:546-585`, **Verified**). The `judge_task` strings describe each kind, but only the judge reads them (**Verified**).

"Experienced" on `/welcome` saves only `learning_track: "none"`, so `skill_level` stays at its `junior` default. Its hint says "Exercises follow the regular difficulty" (`en.yml:28`, `welcome_controller.js#userFor`, **Verified**).

This task adds:
- a hand-written summary and example for each kind;
- a level step after "Experienced".

It doesn't change the planner, prompts or provider calls.

## 1. What I read

- **origin/main is at `01dede726e9fb1282d1eb307d82dbb6668bba1d9`** (#389), the same as local `main`. **Verified**
- **#390 is open, not merged** (head `1a7bca21`, 39 files, mergeable_state clean). **Verified** on GitHub.
- PR 2's plan: `docs/superpowers/specs/2026-10-14-level-suggestions.md` on #390's branch, decision E and "PR 2" item 4. **Verified**

## 2. Deliverable steps after approval

1. Create branch `claude/kind-guides-welcome-level` from `origin/main`.
2. Commit this plan as `docs/superpowers/specs/2026-10-14-kind-guides-and-welcome-level.md`, as its own commit.
3. Stop. No application code, push or PR until you approve the spec.

## 3. Content module: `SectionKindGuide` (decisions 1a, 2a, 7)

`app/models/section_kind_guide.rb`:

```ruby
# Static, never sent to a provider; hand_written_learn_text_spec checks the prose.
module SectionKindGuide
  GUIDES = { "code_review" => { summary: "…", example: "…" }, … }.freeze
  def self.for(key) = GUIDES.fetch(key)
  def self.learn_text # "code_review:summary" => …, "code_review:example" => …
end
```

- **`HandWrittenLearnText::MODULES` gains it.** The existing spec fails if any module defining `self.learn_text` is missing from that list (**Verified**).
- **`spec/models/section_kind_guide_spec.rb`:**
  - `GUIDES.keys == ExerciseSection.keys`, in order.
  - Summaries are at most 2 sentences, examples at most 3.
  - No file under `app/services` or `app/jobs` names `SectionKindGuide`.
- **`hand_written_learn_text_spec` gains a third rule (decision 5): no `!` in any text.**
  - The existing modules contain none (**Verified**, rough grep: 0 matches in `glossary.rb`, `concept_book_sources.rb`, `learn_lessons.rb`).
  - Its fixture check gets a positive and a negative case, like the other two rules.
- **Examples are prose only (decision 2a).** Each one says what you see and what you're asked, never an answer.

**Do the two existing rules fit this copy?** Yes. Every summary and example has more than one sentence, which is the case the same-opening rule checks, and the copy below passes both rules by inspection. Length and exclamation points are now covered by the additions above.

### The copy (S = summary, E = example)

1. **Code Review**
   - S: "Find the one problem in a short piece of code and say how you'd fix it. This builds the habit of reading a change closely before you approve it."
   - E: "You see a ten-line method from a library app that emails members about overdue books. The question asks what's wrong with it and how you'd fix it. On some days the code is a test file or a database migration instead."
2. **Design Comparison**
   - S: "Two pieces of code both work, and you pick the one that suits the system described. Then you name the fact from the scenario or question that decides it."
   - E: "A grocery list app will add new kinds of items later. Piece A and Piece B both save an item today, built two different ways. You choose one and point to the sentence that settles it."
3. **Pattern of the Month**
   - S: "Each day's section names a design pattern and why it exists, then asks how you'd apply it to a stated problem. The answer box starts with headings for the parts a full answer covers."
   - E: "The setting is a gym log, where one button saves a workout, updates a streak and sends a message. You're asked how you'd structure the work using the day's pattern, and you describe it in words. (Revised after review: the pattern section shows no code.)"
4. **Coding Challenge**
   - S: "Write working code for a small task the question describes. Some days you start from a skeleton, and other days from an empty box."
   - E: "The task is a method that sorts a shopping list by aisle, with a sentence saying what it should return. You write the method in the answer box."
5. **Architecture Decision**
   - S: "Choose between two or three ways to build something, and justify the choice by what each one costs. You write reasoning, not code."
   - E: "A library app has to tell members when a book they reserved comes back. One option checks every few minutes, and another reacts the moment the book is returned. You pick one for the situation described and say what you'd give up."
6. **Security Review**
   - S: "Find the one weakness someone could exploit in a short piece of code, and say how you'd close it. It trains you to read code the way an attacker would."
   - E: "You see a short controller action that shows a shared shopping list. The question asks what someone could exploit here and how you'd stop it."
7. **Parsons Problem**
   - S: "Put shuffled pieces of code back in the order that works. Drag them, or move one with Ctrl (Command on a Mac) and the up or down arrow."
   - E: "A short method that totals a gym member's weekly workouts arrives in a random order. You arrange the pieces until the method would run and give the right total."
8. **Plan Review**
   - S: "Read an implementation plan, written as if by an AI assistant, before any code exists. Say what you'd push back on, since a problem costs less to fix in a plan than in finished code."
   - E: "The plan lays out five steps for letting gym members export their workout history. You're asked what you'd want changed before you approve it."
9. **Ambiguity Hunt**
   - S: "Read a vague feature request and write down what you'd need clarified before you could build it. Asking early costs less than building the wrong thing."
   - E: "A product manager writes: “Let people pause their daily practice while they're on holiday.” You're asked what you'd need answered before building it."
10. **Pseudocode to Code**
    - S: "Write the steps to solve a problem in plain words, without worrying about syntax. When your answer is reviewed, Code Gym turns your steps into code exactly as written, so you can see what a missing step would do."
    - E: "The problem is merging overlapping bookings in a meeting room's calendar. You write your steps, and “Check my plan” can point out gaps before you submit."

### What each summary was checked against (all **Verified** unless marked)

| Kind | Claim | Source |
|---|---|---|
| Code review | one problem; test file or migration modes | `code_review.rb:19,45,47,69`; question shape "what's the issue… how would you fix it" |
| Design comparison | both pieces work; fact in scenario or question | `design_comparison.rb:28-29` (junior: in the question), `:179`, placeholder `en.yml:553` |
| Pattern | section names the pattern and why; scaffold headings | `pattern.rb:35-39` (`title` = pattern name, `why`, `answer_scaffold`), `bodies/_pattern.html.erb` |
| Challenge | starter code optional | `challenge.rb:41` "optional skeleton (empty string if none)" |
| Architecture | 2-3 options, not a coding task | `architecture.rb:27,42` |
| Security review | one exploitable weakness plus mitigation | `security_review.rb:8,21,31` |
| Parsons | blocks; Ctrl or Meta plus arrow | `parsons_problem.rb:68`; `ctrlKey \|\| metaKey` in the Parsons controller, line 59. Whether up and down are the arrow keys is from CLAUDE.md, not read in that controller (**Inferred**) |
| Plan review | plan "framed as if written by an AI assistant", pushback before approving | `plan_review.rb:35,46,63` |
| Ambiguity hunt | vague request, "what would you need clarified" | `ambiguity_hunt.rb:41,52,54`, placeholder `en.yml:582`; Code Gym-style requests `:51` |
| Pseudocode | plain-language steps; literal translation at review; Check my plan | `pseudocode_to_code.rb:69`, `review_grading.rb:62-69`, `en.yml:587-590` |

**Judge vocabulary removed:** "planted". I also checked for "anti-pattern", "scope creep", "answer key", "rung" and "pitched", and none appear in the copy.

**Ambiguity hunt answer key (change 7):** the gap categories (scope boundary, edge case, success criteria, data implication, permissions model) exist only inline in the prompt string at `ambiguity_hunt.rb:41`. They are not constants (**Verified**). A spec would have to restate them, so this is a **reviewer check** in the PR description: the ambiguity hunt example and summary must name no gap and no gap category. The copy above names none.

## 4. Where it shows (decision 3a, amended)

**Setup, Exercise mix** (`api_keys/edit.html.erb:155-201`, **Verified**). This is always available.
- At the end of each `.mix-row` in all three loops sits a `<details class="kind-about">` with the summary "About Code Review", opening to the summary and example.
- It has no controller and no save.

**Answer form, until the kind has been answered on a submitted day.**
- **Rule:** show the disclosure for `key` when `!submitted` and the user has no submitted response whose `section_ratings` has the key `key`.
- **Why `section_ratings` keys:**
  - Submitting slices them to `answered_sections` (`responses_controller.rb:263-265`, **Verified**).
  - `submit_blocker` requires every answered section to be rated (CLAUDE.md "One finish action").
  - So on a submitted row, the rating keys are exactly the answered sections. That is the "One answered authority", read back with no new column.
  - A skipped kind keeps its disclosure, since the person hasn't done it yet.
- **Caveat:** that slicing is in a commit dated 2026-10-10 (**Verified**, `git log -S`, `76a7d5e`). Earlier rows that kept a rating on a skipped section would hide that kind's disclosure early. That is harmless (decision 8).
- **Code:** `DailyResponse.answered_kinds_for(user)` is one `pluck(:section_ratings)` over submitted responses, returning a Set. A new `SectionKindGuideHelper#kind_about_on_form?(key)` memoizes it once per request, like `FeaturedConceptHelper#featured_concept`.
- **Placement:** `responses/_section.html.erb` renders the shared `responses/_kind_about` right after `</summary>`, never inside it (`_section.html.erb:7`, **Verified**).
- **Classes:** it uses `kind-about`, not `section`, so `page_structure_spec`'s `details.section > summary` check still matches only the outer element (**Verified**, `:77-81`).
- **Cost:** one small query on the unsubmitted dashboard only. The query never runs for the submitted render, because `!submitted` short-circuits it.

**Left out:** the generating panel (no plan exists yet to say which kinds are coming) and the submitted and History renders.

## 5. Welcome level step (decision 4a, 6)

**How it works:**
- Step 2 stays in the browser, and both values go in one PATCH.
- `WelcomeController#show` redirects once `first_run?` is false (**Verified**, `welcome_controller.rb:6`). Any saved `learning_track` makes it false (`user.rb:231-232`).
- So nothing is saved until the level is chosen, and the gate is unchanged.

**Flow:**
- Step 1 is unchanged. "Early in my career" keeps the same button, `userFor("junior")` body, preset, version and redirect.
- "Experienced" posts nothing. It hides step 1 (`hidden`) and shows step 2.
- Step 2 is a `<section>` with `<h2 tabindex="-1">`, which gets focus. It holds three level buttons in step 1's style and a "Back" button, which restores step 1 and moves focus to Experienced.
- A level button posts `{ learning_track: "none", skill_level: <level> }`, then goes to Setup.
- All buttons on both steps disable while a save is in flight, and a failure re-enables them.

**Server:**
- `ProfileController::TRACK_CHOICE_KEYS[LearningTrack::OFF]` becomes `%w[learning_track skill_level]`.
- Setup's Leave still posts `none` alone.
- `invalid_skill_level?` already refuses values outside `User::SKILL_LEVELS` (**Verified**). The write runs under the existing `with_lock`, because a request carrying `learning_track` takes that path (**Verified**).
- The server doesn't limit the welcome choice to three levels, since Setup already offers principal engineer through the same endpoint (decision 6).
- `user.rb`, `learning_track.rb` and `welcome_controller.rb` are untouched.

**Copy (`learning_track.welcome`):**
- `experienced_hint`: "Pick the level your exercises start at next. Setup lets you change it any time, or set a level for each kind of section."
- `level_title`: "Where should your exercises start?"
- Level names reuse `exercise_mix.levels.*` (**Verified**). Each gets a hint:
  - junior: "New to working in a team's codebase, or changing careers."
  - mid_level: "A few years in, and comfortable shipping features on your own."
  - senior: "You review other people's work and weigh tradeoffs often."
- `back`: "Back".
- The hints describe the person, so they don't restate `KindDifficulty::LEVEL_DEFINITIONS`, which is prompt text.
- The copy promises no suggestions. Non-track accounts get no level suggestions or step-backs until PR 2, so someone who picks Experienced → Junior stays at junior until they change it in Setup. That gap is accepted, and CLAUDE.md will say so.

**Setup skill-level hint: deferred to PR 2.** It stays inconsistent until then: it describes how hard sections "start out", yet nothing moves the setting (PR 2's own finding 6). PR 2 owns the rewrite in its decision E, and its new wording depends on suggestions reaching every account. Rewriting it here would edit the same string twice and create a merge conflict.

**Files:**
- `welcome/show.html.erb`, `welcome_controller.js`, `profile_controller.rb` (the constant), `en.yml`.
- Code notes for the welcome controller and the profile controller.
- `CLAUDE.md`:
  - "Junior learning track": Experienced records `"none"` and the starting skill level it picks.
  - The no-suggestions gap until PR 2.
  - A file-map line for `SectionKindGuide`.

## 6. Files touched, overall

**New:**
- `app/models/section_kind_guide.rb`
- `app/helpers/section_kind_guide_helper.rb`
- `app/views/responses/_kind_about.html.erb` (locals in a one-line header)
- `spec/models/section_kind_guide_spec.rb`
- `docs/code-notes/app/models/section_kind_guide.md`

**Changed:**
- `hand_written_learn_text.rb` and its spec (the `!` rule)
- `daily_response.rb` (`.answered_kinds_for`)
- `api_keys/edit.html.erb`
- `responses/_section.html.erb`
- the layout `<style>` (`.kind-about`, since the partial renders on two pages)
- the welcome files, `en.yml`, `CLAUDE.md`
- the specs listed in §8

**Not touched:**
- the planner, `SectionRotation`, `CompetencyGate`, `DailyPlan`, `AiService` and the providers, the `ExerciseSection` classes, `TrackGraduation`;
- #390's files, except the shared `en.yml`, `edit.html.erb` and the page snapshots.

## 7. Snapshot counts

- **Page snapshots: 5 of 5 change.**
  - Each file embeds `welcome_controller-8f0cff0e.js` twice (**Verified**, count 2 in all five), and step 2 changes that file.
  - Content also changes in `setup.html` (an About disclosure per kind row).
  - Content also changes in `dashboard_unsubmitted.html`: that example creates only today's exercise, so the user has no submitted response and all three sections show About (**Verified**, `existing_account_pages_spec.rb:64-68`).
  - `dashboard_submitted`, `history` and `account` change only in the digest.
  - Re-record with `UPDATE_PAGE_SNAPSHOTS=1`, then read the diff.
- **Prompt snapshots: 0 of 72** (72 files, **Verified**). The zero is **Inferred**; run `generation_prompt_characterization_spec.rb` unchanged to confirm.
- **Request snapshots: 0 of 15** (15 files, **Verified**). The zero is **Inferred**; run `provider_request_characterization_spec.rb` to confirm.

## 8. Test plan

**Model specs:**
- `section_kind_guide_spec`: registry keys, length caps, no reader in services or jobs.
- `hand_written_learn_text_spec`: 20 new texts, and the `!` rule with its own fixture cases.
- `daily_response_spec`, `.answered_kinds_for`:
  - collects keys from submitted responses only;
  - ignores drafts;
  - tolerates a non-hash `section_ratings`;
  - a skipped section (no rating key) is not included.

**Request specs:**
- **Dashboard, unsubmitted:**
  - no history: one `details.kind-about` per section;
  - a past submitted day that answered code review: no About for code review, About still shown for the others;
  - a past day that skipped pattern: pattern keeps its About.
- **Dashboard, submitted, and History:** no `kind-about`.
- **Setup:** one per kind row, whatever the history.
- **`page_structure_spec`** still passes.
- **`welcome_spec`:** step 2 markup (three `data-level` buttons, heading, Back) and the new Experienced hint.
- **Profile:**
  - `none` with each of junior, mid_level and senior saves both values on first run;
  - `none` with a bad `skill_level` returns 422 and saves nothing;
  - `none` alone still works (Leave);
  - `none` with `section_kind_levels` is refused;
  - the junior-preset examples are untouched.

**System specs (`welcome_spec`):**
- Junior is unchanged.
- Experienced → Mid-level → Setup gives `skill_level == "mid_level"`, `learning_track == "none"`, levels `{}`, version 0.
- Back returns to step 1 with focus on Experienced.
- A failed level save re-enables the buttons and stays on step 2.

**Isolation (`learning_track_isolation_spec`):**
- It passes untouched (**Inferred** from reading it, `:1-66` **Verified**; confirmed by running it).
- Its prompt test compares generation and judge calls, and this change reaches neither.
- Its source scan covers `app/services`, `app/jobs` and four named models. None of the new code is in those places, and none of it reads track state.

**Run order:** each file while working → the unit suite → `spec/system` → RuboCop and `bin/comment-check`.

**Accessibility (360px, Playwright; audit §2 and §6):**
- About summaries are at least 24px tall, aiming for 44.
- The accessibility tree reads "About Code Review, collapsed".
- No horizontal scroll at 360px at 140% text.
- Answer-form tab order: section summary → About → scenario → answer → ratings.
- On welcome step 2, the heading is focused, the tab order is the levels then Back, and the hidden step 1 is not focusable.
- VoiceOver steps are listed for you to run on an iPhone.

## 9. Sequencing with #390 and PR 2

**#390 overlap** (**Verified** from its patches):
- `en.yml`: it edits the `proposal.*` block, this task the `welcome.*` block and a new block.
- `edit.html.erb`: it edits line ~138, this task 155-201.
- **All 5 page snapshots conflict.** Resolve them by re-recording after a merge, never by hand.

**PR 2 overlap:**
- **Experienced hint:** PR 2's decision E rewrites it ("Exercises start at the junior level. Set your skill level in Setup…"). Once this step exists that sentence is false, so **PR 2 must drop that rewrite**, adding its suggestions sentence only if one is still wanted. This spec records that. I won't edit #390's branch or its spec.
- **Setup skill-level hint:** PR 2 alone, so no collision.
- **Exercise mix:** PR 2 puts its switch above the difficulty controls, and this task puts About at the end of each kind row. PR 2 starts from main after #390 merges, so landing this first leaves it nothing to merge.

**Order:**
1. #390 merges.
2. This branch merges main and re-records the snapshots.
3. This lands.
4. PR 2 starts.

## 10. Decisions

**Made:** 1a standalone module, 2a prose only, 3a amended by change 4, 4a, 5 yes, 6 as recommended, 7 `SectionKindGuide`.

**Approved 2026-10-15:** 8a and 9 (hide once answered).

8. **"Answered on a submitted day" source.**
   - (a) **Recommended:** `section_ratings` keys on submitted responses. This is answered-only and one small `pluck`, with the pre-2026-10-10 caveat above.
   - (b) `concept_tags` keys. Cheaper still, but these record *shown* sections, so a skipped kind would lose its About.
   - (c) Recompute `answered_sections` per row. Exact for old rows, but loads every submitted response with its exercise on each dashboard load.
9. **Hide or collapse once answered.** You asked for hidden, which is what the plan does. The alternative keeps it on the form forever, collapsed. I see no reason to prefer it.

## 11. Could not check

- VoiceOver on an iPhone.
- The prompt and request snapshot runs, which happen during implementation.
- How `en.yml` merges against #390 until it lands.
- PR 2's final scope beyond its plan.
- How many production rows predate the 2026-10-10 rating slice. I won't read production data.

## 12. Deviations found while implementing

- **All 5 page snapshots also gain the `.kind-about` CSS lines.** The styles sit
  in the layout's `<style>` because the partial renders on two pages, and every
  page carries the layout. `dashboard_submitted`, `history` and `account`
  therefore change by the digest and those lines, not by the digest alone.
- **`profile_skill_level_spec` pinned the old rule** that a skill level cannot
  ride with a track choice. The rule changes on purpose, so that example now
  pins the new one: a skill level rides with `none`, and any other field still
  refuses the request.
- **A Leave may carry a skill level.** `TRACK_CHOICE_KEYS` lists keys per
  choice, not per caller, so an on-track user posting `none` with a level is
  accepted. Setup saves the same field on its own, so nothing new is reachable;
  a request spec pins it.
- **A failed welcome save puts focus back on the pressed button**, since
  disabling it during the request dropped focus to the page.
