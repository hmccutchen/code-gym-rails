# Code blocks are highlighted on the server

every code block on a
page, exercise snippets, schemas, comparison pieces, Parsons blocks,
improved code, pseudocode translations, Learn code examples, the code
fragments of a Learn worked example (split from its prose by
`WorkedExample`) and hand-written lessons, renders through `highlighted_code`, which calls
`CodeHighlight.html`. That is the one place code becomes HTML: Rouge's own
HTML formatter escapes each token, and only its output is marked safe.
`CodeHighlight::LineFormatter` wraps each source line in a `.code-line`
carrying `--indent`, so the layout can give a wrapped line a hanging
indent. Outside strings and comments it also puts alignment padding past
its first space in `.code-align-extra` and a `<wbr>` after each `.` or
`(`, so a wrapping block can hide the padding and break a call chain
between names. The language picks the lexer (`CodeHighlight::LEXERS`);
anything else, architecture pseudocode or a lesson's diff, is plain text,
which still escapes. Output is cached under the lexer and the code's
digest in `CodeHighlight::CACHE`, a bounded store in each process's
memory, and never stored on a row. It is deliberately not `Rails.cache`:
production's Solid Cache would make every block a database query, and
/history renders dozens. A deploy starts it empty, so it can never serve
old markup. No page loads a browser highlighter.
The `code-lines` controller, mounted once on the layout's `<body>`,
decides only what needs the rendered width: whether a block wraps, which
hides its padding. Duck, follow-up and alternate-explanation replies are
built by their controllers as plain text and show no code blocks.
