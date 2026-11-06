---
paths:
  - "app/models/practice_adjustment.rb"
  - "app/services/practice_generation.rb"
  - "spec/prompts/practice_guidance_spec.rb"
  - "app/clients/{ai_service,fake_service,caller_zone_thread}.rb"
  - "app/prompts/{generation_prompt,section_judge_prompt,section_context,pseudocode_prompt,duck_prompt}.rb"
  - "app/models/{problem_set_ingest,planted_key}.rb"
  - "app/models/planted_key/**"
  - "app/services/{judged_generation,exercise_draft}.rb"
  - "app/prompts/generation_prompt/**"
  - "app/services/judged_generation/**"
  - "app/models/{exercise_section,concept_vocabulary,language_prompts,scenario_pools,concept_bucket,real_source,judge_verdict,verdict_schema,code_format,daily_exercise,suggested_concept,mermaid_source,bug_hunt_gotchas}.rb"
  - "app/models/exercise_section/**"
  - "app/models/code_format/**"
  - "app/clients/code_format/**"
  - "app/jobs/{generate_daily_exercises_job,regenerate_exercise_job}.rb"
  - "app/views/responses/bodies/**"
  - "script/{compare_models,model_comparison,forced_concept_drafts,solve_agreement,report_answer_positions,answer_position_balance,key_sheet_export,key_sample_drafts,draft_key_samples,bug_hunt_measure}.rb"
  - "spec/fixtures/judge/**"
  - "spec/**/*{ai_service,judged_generation,exercise_draft,section_judge_prompt,section_context,pseudocode_prompt,duck_prompt,problem_set_ingest,exercise_section,real_source,judge_verdict,code_format,concept_vocabulary,generate_daily_exercises,regenerate_exercise}*"
  - "app/models/{daily_plan,section_rotation,day_hosts}.rb"
  - "app/models/exercise_history_entry.rb"
  - "app/views/responses/answers/_design_comparison.html.erb"
  - "app/views/responses/_answered_sections.html.erb"
  - "app/javascript/controllers/comparison_answer_controller.js"
  - "spec/**/exercise_section/**"
  - "spec/**/*{design_comparison,generation_prompt,section_rotation}*"
---

# Generation, judging and section kinds

Enrolled protected-practice generation takes one captured adjustment per
kind through prompt, retry and ingest. Locks suppress easing and gap help;
only simplified reasoning stamps eased. Validate fixed concepts on the
first draft too, prune extras, and strip provider stamps. Kind-owned format
rules remain unchanged. Gap data never enters logs. See
`docs/decisions/protected-practice-opportunities.md`.

Generation captures assessed performance and delivered-content history as
separate inputs and reuses both on retries. Pending answers and draft
ratings reach neither performance nor its diagnostics; delivered concepts
and scenarios are repetition-only context and contain no answer keys
(`docs/decisions/personalization-loop.md`).
Performance and its completion projection exclude supplementary bug hunts;
delivered repetition history keeps them. One captured server `kind_rungs`
map supplies initial/retry rendering, ingest, ladders, the judge, requested
diagnostics and the new plan-notes snapshot. The draft also captures the
profile's baseline level for rendering and diagnostics. Optional prompt
keywords preserve direct callers' defaults.
Existing unstamped rating-driven easing is not reconstructed (#714).

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Two-stage generation** (`docs/decisions/two-stage-generation.md`): Every
  generation, weekends and regeneration included, drafts a set, then
  `JudgedGeneration` judges each section: keep, edit prose (`.prose_fields`
  only, never code or the planted defect) or reject. There is no single-stage
  path (#703); a script that wants a draft alone calls `ExerciseDraft.call`.
  `RegenerateExerciseJob` runs under a `GenerationDeadline` measured from its
  claim (`DailyExercise::REGENERATION_DEADLINE`; the claim window adds
  `WRITE_MARGIN` for the write after the last call): `#call_and_log` starts
  no call unless its worst case ends in time, a retry also reserves its
  re-judge, a late retry or a retry whose re-judge the deadline stops drops
  only its section, and kept sections land.
  `JudgeVerdict.parse` is the boundary, and evidence is deliberately not
  matched against the section text. A rejection buys
  `DailyPlan::Result#judge_retries` retries (two for a daily kind, one
  otherwise) with the concept fixed, then a drop recorded in
  `dropped_sections`; a retry whose section fails `.reject_unusable!`
  (`UnusableSectionError`) spends one retry and the loop goes on, while any
  other retry failure, a wrong concept or a missing section included, drops
  at once; a retry's prompt names the recorded cause (the judge's principle
  or the refusal code) through one fixed line in
  `GenerationPrompt::RetryReasons`, or no reason when none is recorded, and
  never the draft or the judge's own words; a judge failure keeps the draft,
  except where the kind's `.ships_unjudged?` says no (a `bug_hunt` section,
  or a `code_review` with files, is dropped);
  a day with every section dropped raises `AllSectionsRejectedError` and
  writes no row. A dropped kind still counts as
  scheduled, and nothing in the rotation compensates, on purpose; drops
  supply no workload completion credit. The judge sees one section
  with no concept history, answer keys, `SERVER_STAMPS` or the kind's
  `.judge_hidden_fields`, plus the kind's `.judge_attachment` (a multi-file
  code review's files, every line numbered).
- **JSONB problem sets**: `problem_set` column stores `{ code_review: {...}, pattern: {...}, challenge: {...} }`. Accessed via convenience methods on `DailyExercise`.
- **Closed concept vocabulary**: each section is tagged with one concept from a fixed per-language list (`ConceptVocabulary::RAILS_CONCEPTS` / `JS_CONCEPTS`), narrowed further at generation time for a schema-review `code_review` day (see below); anything a provider invents is normalized to `"other"` so concept history stays aggregatable.
- **Kind difficulty expectations**
  (`docs/decisions/kind-difficulty-expectations.md`): every kind supplies
  `difficulty_definition(rung:, mode:, section:)`, composing the shared
  standard with its own `RUNG_GUIDANCE`. Generation passes mode; the section
  judge, grading and walkthroughs pass the stored section. The same value
  supplies the effective reference rung; ladders retain kind ownership
  until the renderer groups compatible guidance. Baselines remain with ladders,
  which cannot override them or the format. Reuse comparison guidance
  and bug-hunt `RUNG_LINES`/`RUNG_FOR`, including principal as senior;
  never dispatch by kind or mode in shared prompts. Preserve format
  counts, hidden keys, actual-problem grading and historical evidence.
- **`code_review` content modes**
  (`docs/decisions/code-review-content-modes.md`): a weekday's `code_review` rolls
  `application_code`, `test_file` or `schema_review`
  (`DailyPlan::CODE_REVIEW_MODE_WEIGHTS`), and a weekend's is `bug_hunt`; only `schema_review` narrows to
  `DATA_MODELING_CONCEPTS` via `ConceptVocabulary.selectable_for_section`. A
  Ruby `application_code` or `schema_review` day may be grounded in a
  `RealSource` excerpt; `test_file` has no pool. Ingest stamps the server's
  own `scenario` and `source`, plus `current_schema` for a migration excerpt,
  and `RealSource` entries are appended, never inserted. A multi-file day
  (`docs/decisions/multi-file-code-review.md`)
  shows 2 or 3 files (`file_N_path`, `file_N_code`, `file_N_changed` quotes,
  resolved into the server's `file_N_changed_lines`) in
  place of the snippet and diagram, in a range `CodeReview.file_range` sets
  from `DailyPlan::Result#code_review_files` and the rung, and a range of one
  keeps today's prompt byte for byte. `GenerationPrompt` passes the range to
  every kind as `file_range:`, and `ExerciseDraft` hands the same range to
  ingest, whose `.reject_unusable!` refuses a section outside it. Live at
  `multi: 0.25` with guards: the key adds `files` and `evidence`, and one
  that fails (`files_unmatched`, `evidence_unlocated`) is dropped with the
  section kept until keyed grading; the judge gets `MultiFile::JUDGE_GUIDANCE`
  and the grader `MultiFile::GRADING_NOTE`, which reads no key. Files never
  roll on a `bug_hunt` day, and a section with files is dropped when its judge
  fails (`.ships_unjudged?`), as a bug hunt is.
- **`bug_hunt`, the fourth `code_review` mode**
  (`docs/decisions/bug-hunt.md`): A goal line (`purpose`, at most
  160 characters, deleted on every other mode, so it marks the section) and
  at most `BugHunt::MAX_LINES` shown lines of core Ruby or ES-module
  JavaScript with one trap from `BugHuntGotchas`, picked never-seen-first
  into `plan_notes["bug_hunt"]`, never the section, and never the week's
  featured concept (`BugHuntGotchas.pick(featured_concept:)`). Every weekend
  day, never a weekday (`DailyPlan.for(weekend:)`), single-file, never `RealSource`; its
  vocabulary is the picked entry's concept, and every other kind's
  vocabulary that day leaves that concept out. No output: ingest refuses a
  result comment. The key adds an optional code `witness`
  (async witnesses return a snapshot), `looks_right_on` and
  `fixed_snippet`; the quote check reads `issue` only. `purpose` is never a
  prose field. Registry entries are appended, never inserted, and avoid
  traps a formatter rewrites. What needs a re-measure is listed once, at
  the end of the decision doc's measurement section; the run steps are in
  `docs/code-notes/script/bug_hunt_measure.md`.
- **Design comparison, the second fixed section**
  (`docs/decisions/design-comparison-the-second-fixed-section.md`): The second
  default daily kind (`ExerciseSection::DesignComparison`): two working pieces that
  differ on one principle; the engineer picks one and names the deciding fact.
  The server rolls A/B order in `.arrange!`. `answer_key` never reaches the
  page, the judge, the duck (which gains only `piece_a` and `piece_b`) or the
  `[difficulty_diagnostics]` log before review, and the judge's outcomes for
  this kind omit evidence and reason, with the reply parsed `log_raw: false`.
  Each blind solve is a `JudgedGeneration::Solve`, handed back on
  `AiService::JudgedSet#solves` and written to `judge_solves` by the jobs; solves
  never ride `outcomes` or `finish`, and `shipped` comes from the control flow.
  `.reject_unusable!` refuses unusable pieces or keys; `DEFERRED_CONCEPTS`
  stay out of its vocabulary; `.rejudge_edits?` is true only here;
  `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` stays false until a person has read
  the disagreements; its reference stays closed until opened. A day still
  holds at most `ExerciseSection::MAX_SECTIONS`, daily kinds first.
- **Scenario flavor** (`docs/decisions/scenario-flavor.md`): Each day's
  scenario setting comes from one prompt line offering a pool from
  `ScenarioPools::ALL`, rolled once a day by `DailyPlan`
  (`SCENARIO_FLAVOR_WEIGHTS`). Flavor is setting only: concepts come from each
  section's vocabulary, and solving must never need domain or company-internal
  knowledge. `ambiguity_hunt` keeps its own scenario, and a `RealSource`
  `code_review` describes Code Gym.
- **Meta-skill concepts** (`docs/decisions/meta-skill-concepts.md`):
  `ConceptVocabulary::META_SKILL_CONCEPTS` are reasoning skills listed in both
  language vocabularies, hosted only by `code_review` (non-schema modes),
  `pattern` and `challenge`; `parsons_problem` excludes them explicitly.
  `GenerationPrompt::ConceptGuidance#meta_skill_framing_guidance` requires
  such a section to still hold one findable issue, and
  `AiService#annotate_retention_concept` names hosts through `DayHosts`,
  which reads `ConceptVocabulary.selectable_for_section`.
- **The fourth slot** (`docs/decisions/the-fourth-slot.md`): An optional
  fourth key (`plan_review`, `ambiguity_hunt`, `pseudocode_to_code`) with its
  own language-independent vocabularies and buckets, planned on a separate
  track holding one concept (`FOURTH_SLOT_CAPACITY`): reinforcement is cut to
  one and gives the slot up to an overdue retention check. The
  `planted_ambiguities` answer key must never reach the page, a pre-submission
  AI context or logs; strip sites read
  `ExerciseSection.all_answer_key_fields`. `AmbiguityHunt.reject_unusable!`
  refuses only when that kind won the slot, a refusal costs only that section,
  and a wrong planted count is not a failure.
- **Sections are named by kind, never by position**
  (`docs/decisions/kind-named-prompt-sections.md`): every prompt refers to a
  section by its JSON key (`The "architecture" section is…`, the
  fourth-track lines name `@plan.fourth`), since per-user daily kinds make
  the order vary. The fourth-track lines render only when the fourth kind is
  requested, so a retry never names an absent key, and a line comparing
  with another section (`code_review`, `pattern`) renders only when
  `alongside:` (the kinds requested together, so a retry passes none) holds
  it; `generation_prompt_pair_coverage_spec` renders every
  reachable pair to hold both.
  `generation_prompt_section_names_spec` fails on "third section" and the
  like in any prompt snapshot or any Ruby file under `app/` or `lib/`.
- **Which sections count** (`docs/decisions/which-sections-count.md`):
  `DailyExercise#active_section_keys` (through
  `ExerciseSection.resolved_keys`, given the row's own pair from
  `DailyExercise#daily_kinds`) is the single authority for which sections a
  day has; every denominator, the answered count, the submit gate, param
  slices, the duck guard and the review fan-out derive from it. Never count
  `problem_set.keys` or `answers.keys`. `dropped_sections` records why a
  judged day is short.
- **Each section records the rung it was pitched at**
  (`docs/decisions/each-section-records-the-rung-it-was-pitched-at.md`):
  `ProblemSetIngest` strips provider copies, then stamps `pitched_at` (from
  `KindDifficulty#rung_for`) on every returned section, and `eased: true` on
  an unlocked section offered at reduced tier. Both are server-owned. `eased`
  reaches no prompt; `pitched_at` reaches only the review prompt, and the
  judge strips every `ProblemSetIngest::SERVER_STAMPS` field.
- **Exercise code is re-indented once, at ingest**
  (`docs/decisions/exercise-code-is-re-indented-once-at-ingest.md`):
  `ProblemSetIngest#format_code!` runs each kind's `.code_fields` through
  `CodeFormat.all` once, before the boundary checks, so bounds and every
  reader see the shown layout, such as the `code_review` snippet's cap
  (`CodeReview::MAX_SNIPPET_LINES`, which is `RealSource::MAX_LINES` and
  which `SecurityReview` shares): a longer snippet is refused, never cut,
  and design comparison's piece bound counts lines the same way
  (`ExerciseSection.shown_lines`). Ruby uses whitespace-only RuboCop
  `Layout` cops so a planted defect survives; JavaScript uses Prettier. Unparseable code or a formatter that cannot run
  comes back unchanged, and Parsons blocks are never formatted.
- **Stored answer keys** (`docs/decisions/stored-answer-keys.md`):
  `code_review`, `security_review`, `plan_review` and `pseudocode_to_code`
  plant a key under `answer_key` (`.planted_key?`), each in its own shape,
  quoting code or plan text in backticks. A keyed kind extends
  `PlantedKey::Kind`. `ProblemSetIngest#clean_planted_keys!`, its own step
  after the unusable check, stores every keyed section's key cleaned (a slot's loser
  too, since a judged day can ship it) or deletes an unusable one and keeps
  the section. Nothing reads it yet: not the grader, the page, the
  judge or any prompt, and specs pin each place. `ProblemSetIngest` notes
  every keyed section that won its slot, last, as `ok`, `missing`, `too_long` (a field past
  `PlantedKey::MAX_LENGTH`, which drops the whole key, never cuts it), a reason the kind's
  `.unusable_key_reason` names (dropping the key too), or `quote_missing` (a
  backticked span that is neither in the shown code or plan, nor a Ruby
  reference to it, nor in the scenario; the key stays), and
  `GenerationDiagnostics` logs one `[planted_key]` line per note, with its
  attempt, the day's `code_review_mode` and `code_review_files`, the quote tally's counts and no key
  text. The quote match ignores all whitespace. Each backticked span is
  `verbatim` in the code, a Ruby `reference` to it (`KeyReference`), a
  `scenario` match, or `unresolved`, and only an unresolved span makes
  `quote_missing`. Every keyed kind's hidden-key prompt line comes from
  `PlantedKey.hidden_key_line`, ending in `PlantedKey::GROUNDING`.
  Strip sites read `ExerciseSection.all_answer_key_fields`, which stays at
  two entries.
