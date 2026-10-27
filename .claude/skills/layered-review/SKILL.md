---
name: layered-review
description: Layered-design review of a Rails diff, branch or file for sessions that don't have the layered-rails plugin installed, such as a Claude Code cloud session. Checks layer boundaries, callbacks, concerns, service placement and god objects. When the plugin is installed, use /layered-rails:review instead; this is a copy of its review workflow.
disable-model-invocation: true
---

# Layered review

This folder holds the review workflow from the `layered-rails` plugin, version
3.1.0, copied so that a session without the plugin can still run the
layered-design review CLAUDE.md asks of every PR. `NOTICE.md` names the source
and its license.

Run the review through the `layered-reviewer` agent
(`.claude/agents/layered-reviewer.md`), never inline in the session that wrote
the code. The agent reads [`workflows/review.md`](workflows/review.md) and
applies it to the diff, branch or file paths it was given. With nothing given,
it reviews the current branch against `origin/main`.

Only the review and the files it links to were copied: the service-layer audit
it defers to (`workflows/analyze-services.md`) and six references. A link to
anything else opens the upstream file at v3.1.0 on GitHub. A path named in
plain text, such as `references/patterns/form-objects.md` in the audit's
tables, is upstream only. Read one with:

```sh
gh api -H "Accept: application/vnd.github.raw" "repos/palkan/layered-rails-skills/contents/layered-rails/skills/layered-rails/references/patterns/form-objects.md?ref=v3.1.0"
```

To update the copy, copy those eight files again from the new plugin version,
keep this layout, and point any link to a file that wasn't copied at the
upstream tag.
