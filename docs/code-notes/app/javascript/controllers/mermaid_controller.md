# app/javascript/controllers/mermaid_controller.js

## What it owns

Every structure diagram on the page: one dynamic import of mermaid from the
CDN, then one render per diagram container.

## One mount, many diagrams

The controller mounts once on `<body>` and scans for containers. The partial it
replaced emitted one module script per page behind a render-time flag, because
a partial rendered three times would otherwise have shipped the module three
times. Mounting on the body removes the need for that flag: one controller
covers however many diagrams the page holds.

## securityLevel stays strict

Diagram source is model-generated, so it is untrusted input rendered into the
page. Strict is what keeps mermaid from emitting script or following links out
of the diagram.

## data-owns-details decides what a failure removes

A diagram the partial wrapped in its own `<details>` takes that disclosure with
it when it fails, so no empty "Structure diagram" summary is left behind.
Architecture's diagram sits inside a disclosure its caller owns, so only the
diagram is removed.

## A failed import removes every pending diagram

If the CDN cannot be reached there is no renderer for any of them, so each
container is removed rather than left showing raw diagram source.

## Known limit

`connect` returns when no container is present, so a diagram inserted into the
page later would never render. Nothing inserts one today — every diagram is in
the server's first response.
