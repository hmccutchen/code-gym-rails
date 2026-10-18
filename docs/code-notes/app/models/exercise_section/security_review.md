# app/models/exercise_section/security_review.rb

## `.broader_vocabulary_owner` and `.snippet_bar`

Both compare this section with others in the same request, so they name `code_review` or `pattern` only when `alongside:` holds them. A pair without `code_review`, or a retry of this kind alone, gets a line that stands on its own.
