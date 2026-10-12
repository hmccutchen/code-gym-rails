# app/views/shared/_mermaid_diagram.html.erb

## Locals

`source` is the Mermaid text. A blank source, or one `MermaidSource` refuses,
renders nothing at all, so call sites stay a single unconditional line and a
row from before diagrams existed looks the same as a section that chose not
to have one.

`collapsible` (default true) wraps the container in its own closed
`<details>`, matching the dropdown in `shared/_concept_reference.html.erb`.
Architecture's diagram passes `collapsible: false` because it already renders
inside its own `<details class="ref">` (the "Reference — tradeoffs" box), and
a second nested disclosure there would turn a one-click reveal into two.

## Rendering

The partial renders only the container. The layout's `mermaid` controller,
mounted once on `<body>`, finds every container and renders it; see
`docs/code-notes/app/javascript/controllers/mermaid_controller.md`.
`data-owns-details` marks the collapsible branch, so a failed diagram removes
the `<details>` only when this partial created it.
