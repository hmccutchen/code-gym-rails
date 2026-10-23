# app/services/judged_generation/solve.rb

One judge pass on a kind the judge solves blind, carrying every field
`JudgeSolve.record!` reads (`JudgeSolve::SOLVE_FIELDS`; `judged_generation_spec`
fails if a field goes missing). `JudgedGeneration` builds them and writes
nothing; the jobs write them.

- `section` is the kind key, and `judged_section` is the section hash the
  judge was handed, answer key included, copied when the pass ran so that a
  field stamped on the shipped section later can't change it.
- `attempt` is 0 for the draft and the retry number after that. An edit
  check shares its attempt and sets `edit_check`.
- `judge_status` and `judge_pick` are what the judge said, before the
  mismatch switch (`REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL`) turns a verdict
  into a rejection. Both are nil when the judge failed, and
  `unsolved_reason` holds the fallback reason instead.
- `key_better` comes from the kind (`.keyed_solve`), so the service names no
  answer-key field.
- `shipped` and `never_shown_reason` are nil until `SolveChain#solves` fills
  them.
