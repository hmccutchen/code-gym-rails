# script/replay_design_comparison_solves.rb

The entry point for `DesignComparisonReplay`
(`docs/code-notes/script/design_comparison_replay.md`). It parses the flags,
refuses `--run` together with `--synthesize`, and requires `--user` for
synthesis. A dry run is the default, so running it with no flag never makes a
call. A missing `ANTHROPIC_API_KEY` is checked once, in the class, and the
entry point turns that error into an abort with the usage text.
