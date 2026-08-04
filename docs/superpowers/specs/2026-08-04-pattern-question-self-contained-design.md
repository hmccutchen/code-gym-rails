# Pattern question must be self-contained — design

## Problem

Pattern's schema (`AiService#exercise_schema_for`, `app/services/ai_service.rb:497-505`)
has no code-bearing field — no `snippet`, no `code_example`. Only `title`,
`why`, `question`, and `scenario` are rendered to the user. `question` is
meant to be a conceptual, standalone question.

Nothing currently tells the model not to write `question` text that implies
a code snippet is present ("look at the code below," "given this
implementation…"). When it does, the question is unanswerable — there is no
code anywhere on the page for the user to look at.

## Fix

Extend the inline description of the `"question"` field in the pattern
schema block to explicitly forbid code-referencing phrasing, matching how
other fields in this schema self-document their constraints (e.g.
`teaching_note`'s "never the answer"):

```ruby
"pattern": {
  "title":    "string — pattern name",
  "why":      "string — one sentence on why the pattern exists",
  "question": "string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \"the code below\" — none is shown for this section.",
  "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
  "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
  "concept": "string — exactly one concept from the provided vocabulary",
  #{glossary_field}
},
```

This is a prompt-instruction-only change: no schema keys added or removed,
no changes to `code_review`, `challenge`, `architecture`, `security_review`,
or `parsons_problem` blocks.

## Test

Add a spec in `spec/services/ai_service_spec.rb` under the existing
`describe "#build_exercise_prompt"` block, following the convention already
used there (e.g. the `"never the full answer"` teaching_note assertion):
call `build_exercise_prompt` and assert the rendered prompt includes the new
forbidding language for pattern's `question` field.

## Out of scope

- No changes to any other section's schema.
- No changes to response validation, parsing, or the review path.
