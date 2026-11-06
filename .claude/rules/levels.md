---
paths:
  - "app/models/level_suggestion.rb"
  - "app/models/level_suggestion/**"
  - "app/models/{track_change,level_change,level_suggestion_event,level_suggestion_step,user,kind_difficulty}.rb"
  - "app/forms/profile_update.rb"
  - "app/controllers/{welcome,profile,level_suggestion_answers,level_suggestion_dismissals,api_keys}_controller.rb"
  - "app/views/welcome/**"
  - "app/views/dashboard/_level_suggestion.html.erb"
  - "app/views/api_keys/**"
  - "app/javascript/controllers/{level_suggestion,save_switch,welcome,exercise_mix,profile_preferences}_controller.js"
  - "script/{prepare_junior_ladders,junior_ladder_preparation}.rb"
  - "spec/**/*{level_suggestion,track,welcome,skill_level,profile}*"
  - "app/controllers/dashboard_controller.rb"
  - "spec/**/level_suggestion/**"
  - "spec/**/*api_keys*"
---

# Tracks, skill level and level suggestions

Proposal evidence is per kind/date over 180 user-local calendar days,
inclusive of today minus 179, without a global row cap. A new offer needs
own-kind freshness through today minus 29. Lower offers additionally need
two distinct valid concept/bucket identities among the too-hard evidence.
Keep the existing thresholds, cutoff/rung rules and explicit Apply; practice
never changes targets. See `docs/decisions/protected-practice-opportunities.md`.

Suggestion evidence retains sixty qualifying response days across kinds,
filtering basic and strict eligibility before the limit. The newest date
comes from retained strict results, so skipped or malformed review-only
activity and supplementary bug hunts cannot advance a dismissal cutoff or
occupy the retained window. Non-bug weekend evidence still counts. Rung and cutoff policies remain
unchanged (`docs/decisions/level-suggestions.md`).

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Tracks** (`docs/decisions/tracks.md`): A track is `skill_level` itself,
  stored nowhere else, and sets baseline difficulty. It supplies no initial
  mix preset or ongoing kind-frequency bias; track changes never rewrite
  weights or exclusions. Kinds remain available subject to explicit settings.
  Principal engineer remains manual-only, and difficulty-lock protections
  remain unchanged. No preset targets are written. `/welcome` asks once
  (`User#first_run?`: no `track_chosen_at` and no exercise);
  `PATCH /profile` with `choose_track` checks exactly two keys and a
  `LevelSuggestion::LADDER` level under the user-row lock, else 422.
  `TrackChange` previews effective-rung changes through `KindDifficulty`,
  retaining every explicit target and lock, including either baseline.
  Selection only previews; Apply posts a closed from/to/preferences-version
  confirmation to `PATCH /profile`, checked under the user lock. Cancel
  restores only the saved track control. `ProfileUpdate` records cutoffs and
  writes event rows through `LevelChange`, in one transaction, before and
  after the save; `User` has no level callbacks, so a save outside
  `ProfileUpdate` records none. Suggestions never reach principal
  engineer. `track_chosen_at` is a flag, not a clock. `users.learning_track`
  is in `User.ignored_columns` and nothing reads or writes it; the next
  release drops it. A post carrying `learning_track` still gets a 422.
- **Future graduation** (`docs/decisions/tracks.md`): The approved #709
  direction is not implemented. Per-kind advancement earns harder
  opportunities; an overall track-change offer needs broad, sustained
  next-level evidence and must preserve easier kinds. It is an in-app
  milestone, separate from Automatic workload size, not professional
  seniority. The established "Suggest level changes" opt-out also covers
  future graduation offers. Breadth, thresholds, windows, eligibility, other
  presentation details and protection for untargeted kinds remain open.
  #720 preserves explicit targets on manual changes; protecting an easier
  untargeted kind during graduation still needs its own decision.
- **Level suggestions** (`docs/decisions/level-suggestions.md`): One-rung
  level proposals per section kind on the submitted dashboard; nothing moves
  without an explicit Apply. `LevelSuggestion` reads only answered, un-eased,
  `pitched_at`- and `RUBRIC_VERSION`-stamped results, never suggests to or
  from principal engineer, and skips locked kinds. A rung change records a
  cutoff under the user-row lock (`LevelChange#record_cutoffs`), except a move
  to principal engineer and the first-run track choice, which record none.
  Posted `LevelSuggestionStep`s whose `from` differs from the stored rung get
  a 409. Generation, review, both judges, `ConceptMastery` and
  `KindDifficulty` never read track or suggestion state
  (`level_suggestion_isolation_spec`).
- **Skill level control** (`docs/decisions/skill-level-control.md`): Skill
  level choices are `KindDifficulty::LEVELS` (`User::SKILL_LEVELS`), edited
  only from Setup's Track select and the welcome page through `PATCH
  /profile`, which 422s anything outside the list. It sets the rung of every
  untargeted kind and never changes automatically. Under the user-row lock it
  preserves all targets and gives every kind it actually moves a cutoff and
  a `skill_level_edit` event row. A baseline-only change does not bump
  `section_kind_preferences_version`, so Apply checks the confirmed baseline
  as well as that version. A stale Apply refreshes the preview and requires
  another explicit Apply; it never retries the write automatically.
