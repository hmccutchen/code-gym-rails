---
name: intent-log
description: Keep docs/intent-log.md, one short list per day of what a person worked on, each line tagged with the PR it produced and carrying the reasoning behind it, so a teammate can see where the work got to, and tell what was intended from what merely happened, without reading every pull request. Use when asked to write, update, backfill, or reconstruct an intent log, or to catch a colleague up on a burst of agent-assisted work.
---

# Intent log

A team ships faster than it can review. The code is in git; what the person
*wanted* is not, and that is what a returning teammate actually needs. This
skill keeps `docs/intent-log.md`: one short list per day of work, in
chronological order, tagged with PR numbers.

## Format

```markdown
## Fri Aug 14

- the pier: find-yourself map, quests, sponsors, wildlife `#26`
- changed my mind on placement: a random free spot each, so you search for
  your friends
- sponsor banners on rooftops, sized by tier, never overlapping anyone
- leg repair I approve in admin rather than something that just happens `#25`
  **why:** characters generated on production came back with their legs cut off
  **I decided:** I approve each repair rather than have one happen to a card I
  never looked at, and last year's bad cutouts get a free recut
- a "send hi" button on a card that opens a Slack DM

*From review: `#28`*
*Could use a hand: the Slack DM deep link. I decided it's a whole feature and
postponed it, still want it.*
```

**One list of what the person worked on. The PR tag says where it got to**, so
nothing needs a second list to report an outcome:

| tag | means |
| --- | --- |
| `` `#26` `` | merged, it's done |
| `` `#61 open` `` | still in progress |
| `` `#7 dropped` `` | the PR was closed |
| no tag | nothing shipped for it |

Read the state off `gh pr list`, never off memory, and tag each PR **exactly
once**, on the bullet naming the work it came out of. That bullet is often on an
earlier day than the PR: the ask goes where it was made, and the tag follows the
ask. Newest entries at the **bottom**.

A merged PR that abandoned the thing is the one case the tag gets wrong on its
own, so the bullet says it, in words: *gave up on the ocean at any volume*,
tagged with the PRs that took it out.

**A heading carries no year, so the first one names its own**: `## Wed Jul
15-16, 2026`. Every heading after it carries that year forward until another
names one, and the January that opens a new year names itself, `## Fri Jan 1,
2027`. A log that anchors nothing is dated to whatever year it is *read* in, so
from the January after it was written every weekday in it is wrong and the
entries sort into the wrong order. `compose.rb` refuses a day that goes
backwards without naming a year rather than guessing whether it is the new year
or a misordering.

## What goes in a bullet

**One ask, one line, under 20 words.** The bullet is the index. If it needs a
second clause to justify itself, the justification goes on a `**why:**`
sub-line under it rather than into the bullet.

**No before-state and no flourish in the bullet itself.** The reader knows what
the app looked like last week and can read the diff for how it changed. Vova's
example:

> Our invitation emails were still in last year's plain style when we'd already
> built the pixel design, so they got dressed properly

is one bullet: `invitation emails in the pixel design`.

**Name the concrete thing.** "Two fields that both mean the name" is unreadable
a week later; "`name` and `full_name`" is not. A vague noun is the single most
common way one of these entries goes stale.

**Say where an idea came from** when it wasn't the author's: a reviewer, a
player, the team. That is the collaboration signal a teammate reads the log for.

**Name colleagues, and not the people using the thing.** A reviewer and a
teammate are named because the log is partly addressed to them; whoever hit the
bug is "a player". A log outlives the week it was written in and gets read
outside the team — this repo publishes one as its own example — and somebody
named beside a bug they hit, or a limit they took all of, did not agree to
that. A page or a record is not a person: "Rosa's RubyEvents line" names which
page was wrong and stays.

**Say a thing once.** Not in a bullet and again in the help line.

Plain and laid back, first person, the way the person actually talks. No
"leveraged", no "implemented", no "successfully". Prefer the verbs of intent:
asked, wanted, refused, decided, changed my mind.

## The sub-lines, and what they are for

Svyat reviews a PR and cannot tell the human's premise from the model's
additions: five libraries, three models and a refactor into jobs all read the
same in a diff. **The log answers that by recording human decisions only.**
What somebody asked for is here; anything in the diff that is not here was the
model's idea. Nothing needs to say so, and nothing needs to be guessed at.

Two sub-lines carry the reasoning, indented two spaces under the bullet they
belong to, neither of them mandatory:

- `**why:**` carries the state of the world that made the ask. The bug seen,
  the thing that read wrong, the question asked before the work started.
- `**I decided:**` carries the call the human made inside the work, above all
  one that closed off an alternative: a number picked, a check dropped, a
  shape turned down.

**A sub-line never cites a PR number.** `check.rb` counts every `#12` in an
entry and a second mention reads as the same PR tagged twice. Name the work
("his review on the Luma PR") rather than its number.

**Every sub-line is read off the prompts, never inferred from the diff.**
`extract.rb dump` is what the human actually typed. A decision you cannot
point at a prompt for is one the model made, and it stays out. A bullet with
nothing to say under it stays one line.

**Write the reasoning in the human's own terms, not the code's.** "the two
positions disagreed and a reply came back refused" is what was wanted; "unified
the reach check in `Pier::SayForm`" is what the diff already says.

## What stays out

Back and forth is the default condition of the work, so narrating it carries no
information. Cut reviews run, tests written, iterations tried, servers
restarted, things checked on a phone. A reversal is an ordinary Wanted bullet:
`changed my mind on placement: everyone gets a random spot`.

Three things earn a tail line instead, because they are what a colleague can act
on:

- `*Dropped: ...*` — gave up, nothing landed
- `*Postponed: ...*` — parked it deliberately, still wanted
- `*From review: `#28`*` — work the agent started and the human never asked for,
  so the PR is still accounted for
- `*Could use a hand: ...*` — genuinely stuck or wanted. This is the point of
  the whole file: it turns a diary into a list a colleague can act on.

**A day stays under 400 words**, even if it produced 18 PRs. The bullets
alone should still read as a short list: a long day is long in sub-lines.

## The file header is two sentences and a byline

Say what the log is and that it is one list a day, then start. Resist
explaining the conventions inside the file: a reader works out `#22 dropped` and
`*From review:*` on sight, and a page of preamble is the first thing that makes
somebody stop reading a document meant to be read in five minutes. The rules on
this page are for whoever writes the log, not for whoever reads it.

## Updating (the normal case)

**Write the entry on the branch, as the last thing before the merge.** The work
is still in hand, the PR number already exists, and the entry rides in the PR it
describes, so tagging a PR never costs a PR of its own. Reconstruction a week
later is what this replaces, and it was lossy every time.

1. Open the PR first: the entry names its number, so there has to be one.
2. `ruby <skill>/extract.rb dump <YYYY-MM-DD> --repo <repo>` for the prompts
   behind the work. Sub-lines come from what was typed, never from the diff.
3. `gh pr list --state all --limit 100 --json number,state,title,createdAt,mergedAt`
   for anything else still untagged. **Convert those timestamps to local time**;
   `gh` returns UTC.
4. Write the list, appending at the bottom of your own `docs/intent/<login>.md`.
5. `ruby <skill>/compose.rb`, then `ruby <skill>/check.rb docs/intent-log.md`.
6. Commit it onto the branch, push, and merge.

**Tag the PR you are about to merge bare** — `` `#160` `` rather than
`` `#160 open` ``. It is open while you write the line and merged a minute
later, so `open` is stale on arrival, and under this loop every PR would arrive
that way and need correcting by the next one. `check.rb` allows a bare tag for
the PR whose head branch is checked out, and nowhere else: standing on the
branch is what says you are about to merge it.

A day's other work — the asks that shipped nothing, the reversals, the things
you decided against — has no merge to hang off. It goes in the same entry while
you are there, which is the other reason to write at the merge rather than after
it: that material is in the prompts of the block you are already reading.

**When a day ends without a merge**, write it anyway rather than letting it
stack up; `intent-nag.rb` is the backstop and it only speaks at three days
behind, by which point the reconstruction is already lossy.

## A team writes one file each

**Nobody can write anybody else's entry.** `extract.rb` reads
`~/.claude/projects/` on the machine it runs on, and staging is gitignored
because a prompt carries whatever was pasted into it: the staging this skill was
built against holds a live `/c/<token>` sign-in link and a production console
session. The prompts never travel, so each person writes their own days and
that is the constraint the rest of this follows from.

**Each person owns `docs/intent/<github-login>.md` and appends only to it.** Two
people appending to the bottom of one file conflict on every commit that shares
a day: friction at two, a conflict per person per day at ten. Separate files
cannot. The name is the GitHub login because `gh pr list` returns one, so
`check.rb` can say whose entry a PR is missing from without being handed a
mapping.

**`compose.rb` merges them into `docs/intent-log.md`**, which stays the file a
teammate reads and links, and which is generated: edit your own, never that one.
A conflict in it is settled by running `compose.rb` again rather than by hand.

**A day with one author gets no byline**, so a solo log composes to exactly the
file it already had. One author is the degenerate case of ten rather than a
second format, which is why there is nothing to migrate and nothing to choose
between. A day with two or more gets a `### Name` each, and the word cap is one
person's day rather than the whole team's.

**A `*Could use a hand:*` line is lifted to the top of the composed log**, with
the name and the date beside it. At ten people a day is ten lists and the one
line in it somebody can act on is the one that gets buried, which is the whole
point of the file. It stays until whoever wrote it deletes it, nothing else
knowing it was answered.

**A teammate who ships and writes nothing is what `check.rb` gains here**, and
it is the failure a team log has that a solo one cannot: every entry present is
correct and a person is missing. It names an author with PRs and no file of
their own, and it refuses a composed log that is behind its sources, so a day
written and never composed is caught rather than shipped.

The display name is the first `# Irina` line of a person's file, and
`docs/intent/_header.md` is the composed header if it exists.

## Backfilling a repo for the first time

Same loop, one work block at a time, oldest first. Read the whole range's blocks
before writing anything, because threads span days: a decision on Saturday
evening ships on Monday.

**A day is a work block, not a calendar date.** `extract.rb` segments on a
five-hour idle gap, so a session running to 01:00 stays with the day it started.
Label the entry with the date the block began.

**Attribute PRs by evidence, not adjacency.** Match a PR's opened-at time to the
prompt window before it in the same block. A PR with no matching prompt is
*unexplained*: look at it before writing it off as review noise, because the ask
may sit in a worktree session or a parallel one.

## Traps

These each produced a wrong log before the scripts existed:

- **Transcript timestamps are UTC.** Bucketing by the raw date moves anything
  before 07:00 local onto the wrong day, and go-live lands a day late.
- **Worktree sessions live in sibling project dirs.** `~/.claude/projects/`
  holds a separate directory per worktree; `extract.rb` globs all of them.
  Missing those makes the author's own asks look like agent-initiated work.
- **Injected content arrives as a user turn.** Skill bodies, image
  placeholders and caveats all land as `type: "user"`, and reading them as
  prompts puts a page of skill documentation in the log. They carry
  `isMeta: true`; filter on that rather than on a list of prefixes.
- **A prompt typed while the model is working is not a user turn.** It lands
  as an `attachment` of type `queued_command`, with the text under `prompt`
  and `origin.kind: "human"`, and if the running turn absorbs it that is the
  only record of it. Reading `type: "user"` alone missed 523 of one person's
  prompts over seven weeks, among them the ones that defined this skill. A
  queued prompt the turn did not absorb is delivered again as a user turn, so
  the reader drops a queued one whose text the same transcript delivered.
- **Parallel sessions interleave.** One day may hold three sessions on different
  branches. They merge into one entry; `extract.rb` marks blocks that span
  more than one source with `[+worktree]`.
- **The author's memory of dates is a hypothesis.** Check it against the
  transcript before rewriting an entry.
- **A year is only in a heading if somebody wrote it there.** Both scripts fall
  back to the current year, which is right while a log is being kept and wrong
  every January after, so the first entry names its year and `check.rb` asks for
  it when it does not.

## Verifying

`check.rb` asserts every PR you opened since the date in `docs/intent/_since`
appears exactly once with the right state marker, entries run oldest first,
every day is a list, no bullet runs to a paragraph, and no day runs long.
`--all` checks everybody's PRs instead of yours, and a bot's PR is never owed.
Run it after every write; it catches dropped PRs that reading cannot. `--fix` rewraps the file, keeping
bullets hanging-indented.

## Capturing as you go

Reconstruction is lossy and slow. `intent-stage.rb` is a `SessionEnd` hook that
drops each session's prompts into `.intent/staging/<date>.jsonl` (gitignore it),
so the daily entry is written from fresh material rather than archaeology. It
also sidesteps the timezone and worktree traps, because a session knows its own
transcript and cwd.

**`intent-nag.rb` is the other half of that, and the reason this file needs
one.** Staging runs itself and the write-up does not, so a log lapses in
silence: the one this skill was built against ran from Aug 18 to Sep 3, 62 PRs,
while the hook beside it staged every one of those days perfectly. Nothing
noticed because nothing was looking. It is a `Stop` hook that counts the staged
days the log has not accounted for and hands them back at three or more
(`INTENT_NAG_DAYS`), reading your own file so a teammate logging today does not
answer for you. It marks the attempt before it makes it, so a session that says
no is not asked twice, and it fails open on everything else: no staging, no log,
no `gh` — all exit 0.

Register both per-person in `.claude/settings.local.json`, never in the committed
`.claude/settings.json`, so nobody inherits a hook they did not ask for:

```json
{"hooks": {
  "SessionEnd": [{"hooks": [
    {"type": "command", "command": "ruby \"$CLAUDE_PROJECT_DIR/.claude/skills/intent-log/intent-stage.rb\"", "timeout": 15}
  ]}],
  "Stop": [{"hooks": [
    {"type": "command", "command": "ruby \"$CLAUDE_PROJECT_DIR/.claude/skills/intent-log/intent-nag.rb\"", "timeout": 15}
  ]}]
}}
```

Install it only when asked.
