---
paths:
  - "app/controllers/{learn,learn_lessons,concept_references,concept_drills,progress}_controller.rb"
  - "app/controllers/concerns/learn_scope.rb"
  - "app/models/{concept_reference,concept_lesson,concept_group,concept_book_sources,learn_lessons,glossary,hand_written_learn_text,section_kind_guide,recognition_guide,featured_concept,rung_ledger,concept_hosts,worked_example,ladder_coverage}.rb"
  - "app/services/featured_concept_pick.rb"
  - "app/jobs/{generate_concept_reference_job,generate_recognition_guide_job}.rb"
  - "app/helpers/{featured_concept,concept_references,concept_drills,progress,section_kind_guide,glossary}_helper.rb"
  - "app/views/{learn,learn_lessons,progress}/**"
  - "app/views/shared/{_concept_reference,_featured_concept}.html.erb"
  - "app/views/responses/{_featured_marker,_kind_about,_kind_guide}.html.erb"
  - "app/javascript/controllers/{concept_alternates,learn_filter,write_up_control,glossary}_controller.js"
  - "spec/**/*{learn,concept_reference,featured,progress,rung_ledger,recognition,lesson,book_source,kind_guide,glossary,hand_written}*"
  - "app/models/concept_vocabulary.rb"
---

# Learn, Progress and the featured concept

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Alternate framings of a concept reference**
  (`docs/decisions/alternate-framings-of-a-concept-reference.md`): A control
  inside a concept reference asks
  `ConceptReferencesController#explain_differently` for another explanation,
  capped at `MAX_ALTERNATES_PER_CONCEPT`. Nothing is persisted and the shared
  `ConceptReference` row is never written.
  `AiService#explain_concept_differently(user, reference, prior_alternates:)`
  takes no exercise, response or section, since it runs before submission; a
  spec pins that signature.
- **The Learn tab** (`docs/decisions/the-learn-tab.md`): `/learn` lists every
  concept in the user's slice by `user.language`, never `#language_for_today`,
  and shows explanations before first exposure on this tab only.
  `ConceptReference` is a team-wide cache keyed on `(concept, language)` with
  no `user_id`. Guide, ladder and `lesson` come from the same
  `#generate_concept_reference` call, outside its required fields;
  `CONCEPT_REFERENCE_FIELDS` stays unwidened, `TRADEOFF_CONCEPTS` is written
  out, and "seen" reads `concept_exposure_count`, never `ConceptMastery`.
- **Recognition guides** (`docs/decisions/recognition-guides.md`): Each named
  `ConceptGroup` or language-independent bucket gets one shared
  `RecognitionGuide` on how to look for that kind of problem. It teaches a
  process and never defines a concept or hints at a defect:
  `#generate_recognition_guide(user, group_key)` is handed no exercise,
  response or history. All three fields are required, rows are never
  rewritten, and nothing else reads a guide.
- **Book citations** (`docs/decisions/book-citations.md`):
  `ConceptBookSources` maps a concept to an array of hand-curated reading
  pointers (title, author, coined term), shown only on `LearnController#show`.
  It must never reach a provider prompt (a spec pins this), and
  `CONCEPT_REFERENCE_FIELDS` and `ConceptReference::GUIDE_FIELDS` stay untouched by it.
  A pointer names a term the book coined, never a chapter or page number.
- **Hand-written lessons** (`docs/decisions/hand-written-lessons.md`):
  `LearnLessons` holds static lessons for Learn-only concepts in no
  vocabulary, rendered at `/learn/lessons/:lesson`; they never reach a
  provider, generation, `ConceptMastery`, retention, drills or Progress. Every
  static reader-facing module is listed in `HandWrittenLearnText::MODULES` and
  answers `.learn_text`, which a spec holds to the plain-language standard's
  checkable rules.
- **What each section kind is**: `SectionKindGuide` holds a hand-written
  summary, a short example and a one-line `short` summary for every
  registered kind. The summary and example are shown in an "About"
  disclosure. Setup's Exercise mix shows one for every kind, always. The
  answer form shows one under a section's summary only until the user has
  answered that kind on a submitted day (`DailyResponse.answered_kinds_for`,
  read from submitted `section_ratings` keys, with no column of its own); the
  submitted dashboard and History never show it as a disclosure. Each row of
  a daily card's swap sheet shows the kind's `short` line, and the checked
  row also shows its example, both read from `SectionKindGuide`; a spec
  requires a one-sentence `short` for every kind. Like `ConceptBookSources` it
  is never sent to a provider, and a spec fails if anything under
  `app/services` or `app/jobs` names it. Each example says what the engineer
  sees and is asked, never an answer, and the ambiguity hunt's names no gap
  and no kind of gap, since the real ones are that section's hidden answer
  key. Its keys must equal `ExerciseSection.keys`, so a new kind fails a spec
  until it has copy.
- **The weekly featured concept**
  (`docs/decisions/the-weekly-featured-concept.md`):
  `FeaturedConcept.for(user)` stores one met concept per user per week
  (`week_of`, the user's Monday), picked by the pure `FeaturedConceptPick`
  from `RungLedger` and exposure, never `ConceptMastery`, drills or pause
  state. `#still_met_by?` re-picks a stale row on read, the insert keeps its
  SAVEPOINT for the unique-index race, it never calls a provider, and
  `#marks?` is the one marking rule. `#featured_tagline_shown?` holds the
  reference's tagline back on the dashboard until the day is submitted, since
  it can name what a section asks the engineer to find.
- **The Progress page shows the rung each concept is held at**
  (`docs/decisions/the-progress-page-shows-the-rung-each-concept-is-held-at.md`):
  `/progress` shows the rung each concept is held at, grouped as Learn groups
  it. `RungLedger` is the one rule: pure over the responses given, never
  compares to today, uses reviewed un-eased sections and co-favourable
  ratings, and shows `developing_toward` between rungs. The page never shows
  tier, `ConceptMastery`, drills, streak or bucket totals; hosts come from
  `ConceptHosts`.
