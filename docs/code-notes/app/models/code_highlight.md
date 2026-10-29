# app/models/code_highlight.rb

## Changed lines

`CodeHighlight.html` takes `changed:`, a list of 1-based line numbers. `LineFormatter` counts lines as it streams them and gives each listed line's `span.code-line` a second class, `code-line-changed`. A multi-file `code_review` uses it to mark the lines a change touched; a number past the last line marks nothing.

The style for that class is a background and an inset left bar drawn with `box-shadow`. It never adds padding or a border, since either would change the line's width, and the `code-lines` controller decides wrapping by measuring line heights against one probe line. A changed line has to wrap exactly where it would unmarked.

## Why the cache key includes the changed lines

`CACHE` holds finished HTML, so two blocks with the same code and lexer but different changed lines are different entries. The key adds `changed.sort.join(",")`, so the order the numbers arrive in doesn't split one block into two entries.

## No change for existing callers

Every caller before multi-file `code_review` passes no `changed:`. With none, every line gets exactly the markup it had before, and the key's extra part is an empty string, so those blocks render the same bytes. `code_highlight_spec` pins this against output recorded before the option existed.
