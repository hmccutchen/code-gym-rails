# Hand-written lessons

`LearnLessons` holds lessons for concepts that
belong on the Learn tab but in no vocabulary, because a generated section
cannot test them. `reading_unfamiliar_code` is the first: moving through a
change and its callers across files is more than a short snippet can hold.
A lesson is static and hand-curated like `Glossary`, never sent to a
provider, and lives outside every `ConceptVocabulary::LANGUAGES` vocabulary, so it never
reaches generation, `ConceptMastery`, retention, drills or Progress. The
Learn index lists it inside the `ConceptGroup` it names, beside its
siblings, and `/learn/lessons/:lesson` renders it read-only.

**Hand-written Learn text meets the plain-language standard through a
spec.** Generated lessons get `PLAIN_LANGUAGE_STANDARD` through their
prompt; text written into code has no prompt.
`HandWrittenLearnText::MODULES` lists every module of static reader-facing
text (`Glossary`, `ConceptBookSources`' pointers, `LearnLessons`,
`SectionKindGuide`), each answering `.learn_text`, and
`spec/models/hand_written_learn_text_spec.rb` holds all of it to the
standard's checkable rules: the placeholder phrases, read from the standard
itself, no text whose every sentence opens with the same word, and no
exclamation point, which is stricter than the standard's "rare emphasis".
The rest of the standard needs a reader's judgment.
