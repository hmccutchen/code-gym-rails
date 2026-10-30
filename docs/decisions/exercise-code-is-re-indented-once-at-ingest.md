# Exercise code is re-indented once, at ingest

models often write code
with uneven indentation, and the highlighter shows whitespace exactly as
written. `ProblemSetIngest#format_code!` passes each kind's
`.code_fields` (code review and security review snippets, challenge
starter code, design comparison pieces) through `CodeFormat.all` in the
day's language, before the boundary checks, so a bound such as
`MAX_PIECE_LINES` or the snippet cap `CodeReview::MAX_SNIPPET_LINES` (shared by `SecurityReview`) applies to the code as shown, and the page, grader,
judge and duck all read the same layout. Ruby goes through RuboCop's
`Layout` cops in process (`CodeFormat::Ruby`), which move whitespace and
nothing else, so a planted defect survives token for token; a spec holds
that. `Layout/LineLength` and `Layout/HashAlignment` are left out, since
one would split lines and the other undo a table the highlighter already
keeps readable. RuboCop's own defaults apply rather than the repository's
`.rubocop.yml`, and `rubocop` is a production gem for this. JavaScript
goes through Prettier (`CodeFormat::Javascript`), one Node process per
set, using its TypeScript parser so JSX and TypeScript snippets format
too. Prettier is not whitespace-only: it adds semicolons and parentheses
and can rewrap a line, which keeps behavior but can make a defect that
depends on how code is laid out easier to see. That is the accepted cost
of the readable layout. Code a formatter cannot parse, such as a Prisma
schema or pseudocode, comes back unchanged, and a formatter that cannot
run at all (no Node, a timeout) hands back the whole batch unchanged and
logs `[code_format] language=… fallback=<class>`, so formatting never costs
a section. Parsons blocks are not formatted, since their indentation is
part of the arrangement. Node reaches the Railway image through the
`Dockerfile`, which Railway builds from: the base stage installs Debian's
`nodejs`, and the build stage runs `npm --prefix vendor/prettier ci`, so
both services carry it. `spec/support/code_format_default.rb` makes every
example hand code back unchanged, since Prettier's presence varies by
machine, and `spec/models/code_format_spec.rb` opts back in; CI installs
`vendor/prettier` so those examples run Prettier for real.
