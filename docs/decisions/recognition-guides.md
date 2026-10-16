# Recognition guides

each recognition group on the Learn index carries
one generated piece on how to look for that kind of problem
(`RecognitionGuide`, table `recognition_guides`), in a disclosure at the top
of the group's block, above its concept list. A recognition group is a named
`ConceptGroup` or a language-independent bucket, whose flat list already is
one group; a language bucket's `core` group has no shared identity and gets
none. The guide teaches a process, never an answer: it never defines one
concept, which is `ConceptReference`'s job, and never hints at a planted
defect. `AiService::RECOGNITION_GUIDE_SCOPE` states that in the prompt, and
`#generate_recognition_guide(user, group_key)`'s signature holds it, since
it is handed no exercise, response or history. It is therefore shown with no
exposure gating. One row per group, shared across languages and the team,
written by `GenerateRecognitionGuideJob` from the existing "Write up the
rest" backfill and never rewritten; all three fields are required, so a
flubbed response writes nothing and the next backfill retries. Two framings
are derived rather than branched: a group holding any `TRADEOFF_CONCEPTS`
gets a line saying those are choices, and meta skill is framed as the habit
its tracked concepts exercise together (`RecognitionGuide::FRAMINGS`),
since its concepts are already process concepts. Nothing else reads a
guide.
