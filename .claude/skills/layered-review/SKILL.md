---
name: layered-review
description: Layered-design review of a Rails diff, branch or file for sessions that don't have the layered-rails plugin installed, such as a Claude Code cloud session. Checks layer boundaries, callbacks, concerns, service placement and god objects. When the plugin is installed, use /layered-rails:review instead; this is a copy of its review workflow.
---

# Layered review

This folder holds the review workflow from the `layered-rails` plugin, version
3.1.0, copied so that a session without the plugin can still run the
layered-design review CLAUDE.md asks of every PR. `NOTICE.md` names the source
and its license.

Read and follow [`workflows/review.md`](workflows/review.md), applied to the
diff, branch or file paths you were given. With nothing given, review the
current branch against `main`.

Only the review and the files it links to were copied: the service-layer audit
it defers to (`workflows/analyze-services.md`) and six references. A link to
anything else opens the upstream file at v3.1.0 on GitHub. A path named in
plain text, such as `references/patterns/form-objects.md` in the audit's
tables, is upstream only; read it on GitHub when you need it.

To update the copy, copy those eight files again from the new plugin version,
keep this layout, and point any link to a file that wasn't copied at the
upstream tag.
