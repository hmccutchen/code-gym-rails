# script/bug_hunt_measure.rb

`build` turns `bug_hunt` drafts into harness files a separate place can
run, and `report` reads back the results. Neither runs drafted code: only
`run.sh` does, inside a container or a workspace with no secrets. The
measurement asks how often a drafted `bug_hunt` section is wrong about what
its code does, and the answer decides whether a production sandbox is worth
building.

## The checks

| Check | Harness | Code | Compared against | Pass when |
|---|---|---|---|---|
| 1, the bug is real | `bug_real` | `snippet` | `witness.expected` | they don't match |
| 2, the key says what happens | `returns_match` | `snippet` | `witness.returns` | they match |
| 3, "looks right" is true | `looks_right` | `snippet` | `looks_right_on.expected` | they match |
| 4, the fix works | `fix_witness`, `fix_looks_right` | `fixed_snippet` | the two `expected` | they match |
| 5, core only | any | | | no harness reports `not_core` |

`looks_right` and `fix_looks_right` exist only when the key has
`looks_right_on`. `report` also counts the snippets with a line past 45
and past 60 characters, for the phone guidance.

**Match** means one of two forms. `raises <ErrorClass>` matches the code
raising exactly that class. A literal matches the code returning without
an error and equal to it: Ruby `==`, JavaScript `isDeepStrictEqual`.

## `build DRAFTS_PATH [DRAFTS_PATH] HARNESS_DIR`

- **Input:** the drafts file or files `draft_key_samples.rb code_review
  --mode bug_hunt` writes, one per language.
- **Names:** each draft is named by its registry place (`rb01` to `rb11`,
  `js01` to `js12`), and each harness `<draft>-<check>`.
- **Files per harness:**
  - a runner from `templates/runner.rb.template` or `runner.mjs.template`
  - a subject: the code, then the call
  - a literal file, only for a literal
- **A key part that is missing** gives a runner whose spec is nil, which
  reports `key_unparsable` without loading anything.
- **Beside the harnesses:** `harnesses.txt` (one line per harness: id,
  runtime, runner), `build_id` (12 random hex characters), `run.sh` and
  `manifest.json`. The manifest holds the build id, each draft's snippet,
  key, rung and line widths, and every harness.
- **The archive:** `HARNESS_DIR.tar.gz` holds the same folder without
  `manifest.json`, at its top level, with no links and `run.sh` at mode
  755. It is written with Ruby's own `Gem::Package::TarWriter` and `Zlib`,
  and `build` prints its SHA-256.
- **Guards:** both outputs must be outside the repository and must not
  already exist.

## The runners and `run.sh`

- **Output:** a runner prints exactly one result, as its last line
  starting with `BUGHUNT_RESULT `, then exits 0.
- **Ruby** runs with `--disable-gems`, so no gem can load. It evaluates the
  code and the call in one `eval` in `TOPLEVEL_BINDING`, so a syntax error
  is caught and reported rather than killing the runner.
- **JavaScript** runs as an ES module (`.mjs`). The subject module exports
  the awaited result of the call. The runner then waits one
  `setImmediate` turn, so pending promise callbacks settle before the
  comparison. It ignores a late unhandled rejection so the result line
  still prints.
- **Snapshots:** because the comparison waits, a witness that returns a
  live reference would be compared in its settled state. The generation
  prompt therefore asks every async witness for a snapshot taken when the
  call returns.
- **`not_core`:** Ruby `NameError` (exactly, not `NoMethodError`) or
  `LoadError`; JavaScript `ReferenceError` or a missing module or package.
- **Limit:** a Rails method called on a core object raises
  `NoMethodError`, which `bug_real` can't tell from a real trap. The fix
  checks fail too in that case, so the draft reaches the failure sheet.
- **`run.sh`** runs every harness in `harnesses.txt` order under
  `timeout -k 1 5`, with stdin from `/dev/null`, and writes
  `results.jsonl`.
  - A harness that hangs is recorded as `timeout`. One that exits
    without a result line is recorded as `no_result`.
  - `run.sh ruby` or `run.sh node` runs one language, and a second argument
    names the output file.
  - It works from any directory, and from the archive extracted into an
    empty one.
- **The network-off wrapper** is set with `BUGHUNT_NETWORK_OFF`:

  | Value | What `run.sh` does |
  |---|---|
  | `auto` (default) | tries `unshare -rn`, then `unshare -n`, and otherwise runs with the network on |
  | `require` | the same, but stops before running anything if neither works |
  | `never` | never wraps |
  | `external` | never wraps, and records that the network is off by other means, such as Docker's `--network none` |

## The results file

`results.jsonl`, one JSON object per line.

- **The first line** is `{"build", "network", "runtime"}`.
- **Then one line per harness:** `{"harness", "outcome", "reason"}`, plus
  `error` when the code raised.
  - `outcome` is `pass`, `fail` or `not_runnable`.
  - `reason` is `matched` or `mismatched`, or for `not_runnable` one of
    `key_unparsable`, `syntax`, `not_core`, `timeout` and `no_result`.
- **No key text** reaches it.

## `report HARNESS_DIR RESULTS_PATH... OUT_DIR [--seed N]`

- **It refuses, writing nothing, when:**
  - a results file is from another build
  - Ruby isn't 3.3.6 or Node isn't 22.x
  - a runtime the harnesses need ran in no file
  - a harness has no line, more than one, or none in the manifest
  - a line has a key or value outside the format
- **Its outcomes:** a draft fails a check when any of that check's
  harnesses is `fail` or `not_runnable`, since a claim that couldn't be
  run isn't a checked claim.
- **`counts.txt`:** the network state of each file, each check's counts,
  the drafts failing check 1, 3 or 4 against the threshold of 2, each
  failing registry entry, and the line widths.
- **`failures.md`:** every failing draft in full, plus 2 passing drafts per
  language picked with the printed seed.

## Running the measurement

Billed calls happen only at step 3, and only after the owner approves the
call count and the cap in the measurement session's chat.

1. **The owner** makes a dedicated Anthropic key for this run, with a spend
   limit of about $5. If the Console sets limits per workspace, the key
   gets a workspace of its own, with access to `claude-opus-5-5` and
   `claude-sonnet-5-5`. The owner adds it as `ANTHROPIC_API_KEY` in the
   cloud environment's settings, never in chat, then starts or asks for
   the measurement session on this branch.
2. **The measurement session** checks the key without printing it
   (`test -n "${ANTHROPIC_API_KEY:-}" && echo set`) and never runs `env`,
   `printenv` or `set -x`. Then it sets up:

   ```
   service postgresql start
   su postgres -c "createuser --createdb root"
   bin/rails db:prepare
   npm --prefix vendor/prettier ci
   dockerd   (in the background)
   docker pull ruby:3.3.6-slim
   docker pull node:22-slim
   ```

   Then, for each language, it runs the drafts script without `--run`
   (`--count 11` for Ruby, `--count 12` for JavaScript) and posts both
   printed call counts and bounds for approval.
3. **Drafting (billed):** Ruby with `--run --max-cost 4`, then JavaScript
   with `--max-cost` set to $4 minus the Ruby run's printed total. The
   drafts files go outside the repository. Then the owner deletes the key
   in the Console and removes the variable from the settings.
4. **Harnesses:** `build` writes one harness folder from both drafts files.
   Then, one container per runtime:

   ```
   docker run --rm --network none --read-only --tmpfs /tmp --memory 256m --cpus 1 \
     --pids-limit 64 --user 65534 --env-file /dev/null -e BUGHUNT_NETWORK_OFF=external \
     -v "$HARNESS_DIR":/in:ro -v "$RESULTS_DIR":/out \
     ruby:3.3.6-slim bash /in/run.sh ruby /out/results-ruby.jsonl
   ```

   The same runs with `node:22-slim`, `node` and `results-node.jsonl`. If
   `dockerd` won't start, the session sends the owner the archive and its
   SHA-256 instead. The owner runs it in a separate workspace with no
   secrets (`bash run.sh` after extracting into an empty directory) and
   attaches `results.jsonl` back.
5. **Report:** `report` with both results files. The session sends the
   owner `failures.md` as a file and posts `counts.txt` in chat.
6. **Clean up:** delete the drafts files, the harness folder, the archive,
   the results and `OUT_DIR`, and remove the two images. Only the counts
   are kept, in the PR description.

**Reading the counts:**
- If checks 1, 3 or 4 fail on more than 2 drafts, the sandbox question goes
  to the owner before the page and mastery work starts.
- An entry whose draft fails check 1 or 3 is cut from the registry.
  Cutting needs no re-measure.
- Check 5 failing tightens the prompt's core-only line, and that change
  needs a re-measure (`--entries` for a partial one).
