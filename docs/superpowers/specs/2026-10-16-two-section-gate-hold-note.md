# Note: an Automatic account can be held at two sections

Status: a product question, recorded for a later decision. No change is
proposed. Found while designing the daily kind swap
(`2026-10-16-daily-kind-swap-design.md`), but it is not caused by swapping.
Checked against `origin/main` at `abf0892`.

## What happens

An Automatic account's day size grows from two to three through
`CompetencyGate`. Growth reads only results whose kind was daily on that
day, by each day's own recorded pair (#411). Until the swap ships, that is
code review and design comparison for every account. On a two-section day
those are the only results there are.

- **Growth from 2 to 3** needs 4 favourable results in the latest 5 daily,
  un-eased ones (`GROW_TO_THREE`). A two-section day adds 2 such results, so
  the window refills within 3 answered days.
- **Suppose one daily kind is non-favourable every day.** Any 5 consecutive
  daily results then include at least 2 from that kind, so at most 3 are
  favourable and 4 of 5 can't be reached. The day stays at two for as long
  as the kind stays hard.
- **If that kind is also rated too hard,** `BRAKE` (2 too-hard in the latest 4)
  fires about every other day and keeps emptying the growth window.
- **At two sections, other kinds appear only through the coverage
  exception:** about once every 6-8 weeks per kind on Automatic, and never on
  a fixed Daily sections setting of 2. So the user mostly sees the pair that
  is holding them.

This is the case on main today. An account that keeps finding code review or
design comparison hard is held at two sections in exactly this way. The swap
doesn't create it. It only lets a user put a different kind into each day's
recorded pair, the gate's only growth input, so it can now also happen with a
kind they chose.

## Exits that already exist

- **The per-kind level suggestion.** Its step-back fires on 2 too-hard among
  the latest 3 results at the current level, about 2 days at two sections.
  Applying it is a level change, which restarts that kind's runs in the gate.
  This is the only exit that needs no thought from the user. It also needs
  the "Suggest level changes" switch on and an explicit Apply, so an account
  with suggestions off has only the manual exits.
- **Swapping the kind out,** once the swap exists.
- **A fixed Daily sections setting** above two.

## The question for later

Should a kind the user keeps finding hard be able to hold their whole day at
two sections? The gate is doing what it was designed to do with the pair it
reads, so this is a product decision, not a defect. These options would each
change behaviour for every account:

- growth could read results pooled across all kinds;
- growth could step a hard daily kind down;
- growth could accept 4 of 5 from either daily kind on its own.

None is proposed here.

## What lands now

One pure `CompetencyGate.plans` spec pins today's behaviour, so any later
decision changes it on purpose:

- a two-section history where one daily kind is non-favourable every day stays
  at two;
- growth resumes within 3 answered days of that kind becoming favourable.

It landed in #411, the swap design's PR 1b, as
`spec/services/competency_gate_daily_pairs_spec.rb`.
