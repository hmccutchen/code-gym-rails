# script/replay_design_comparison_solves.rb

The entry point for `DesignComparisonReplay`
(`docs/code-notes/script/design_comparison_replay.md`). It parses the flags and
requires `--user` for synthesis. A dry run is the default for both the replay
and `--synthesize`, so no call is made without `--run`. A missing `ANTHROPIC_API_KEY` is checked once, in the class, and the
entry point turns that error into an abort with the usage text.
