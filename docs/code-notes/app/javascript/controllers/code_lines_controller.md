# app/javascript/controllers/code_lines_controller.js

## What it owns

The one rendered-width question server-side highlighting cannot answer: does a
code block wrap? `CodeHighlight` emits alignment padding inside
`.code-align-extra`; a wrapping block has to hide it, and only the browser
knows whether it wraps.

## Width-only observation cannot loop

Fitting toggles `data-wraps`, which changes a block's height and never its
width. The observer compares the reported width against the last one it saw
and returns when it is unchanged, so a height change it caused cannot feed
back into another fit.

## It observes the <pre>, not the <code>

An inline `<code>` reports no size of its own, so the observed element is its
parent.

## A hidden block measures zero

A block inside a closed disclosure has a zero-height probe row, which would
make every line look like it wraps. `fit` returns on a zero row and the
observer fits the block when the disclosure opens and it gains a size.

## Blocks without padding are skipped

Only a block containing `.code-align-extra` has anything to hide, so only those
are observed. Everything else costs nothing.
