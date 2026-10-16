---
paths:
  - "app/services/level_suggestion.rb"
  - "app/services/level_suggestion/**"
  - "app/models/{track_change,level_suggestion_event,level_suggestion_step,user,kind_difficulty}.rb"
  - "app/controllers/{welcome,profile,level_suggestion_answers,level_suggestion_dismissals,api_keys}_controller.rb"
  - "app/views/welcome/**"
  - "app/views/dashboard/_level_suggestion.html.erb"
  - "app/views/api_keys/**"
  - "app/javascript/controllers/{level_suggestion,level_suggestions_switch,welcome,exercise_mix,profile_preferences}_controller.js"
  - "script/{prepare_junior_ladders,junior_ladder_preparation}.rb"
  - "spec/**/*{level_suggestion,track,welcome,skill_level,profile}*"
---

# Tracks, skill level and level suggestions

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Tracks** (`docs/decisions/tracks.md`): A track is `skill_level` itself,
  stored nowhere else, and no preset targets are written. `/welcome` asks once
  (`User#first_run?`: no `track_chosen_at`, no `learning_track`, no exercise);
  `PATCH /profile` with `choose_track` checks exactly two keys and a
  `LevelSuggestion::LADDER` level under the user-row lock, else 422.
  `TrackChange` is the one rule for which unlocked targets a track change
  clears, and `User#apply_track_change` stays declared ahead of
  `bump_section_kind_preferences_version`. Suggestions never reach principal
  engineer. `track_chosen_at` is a flag, not a clock. `learning_track` stays
  one release: a choice writes `User::TRACK_CHOICE_MARKER`, and a post
  carrying `learning_track` gets a 422.
- **Level suggestions** (`docs/decisions/level-suggestions.md`): One-rung
  level proposals per section kind on the submitted dashboard; nothing moves
  without an explicit Apply. `LevelSuggestion` reads only answered, un-eased,
  `pitched_at`- and `RUBRIC_VERSION`-stamped results, never suggests to or
  from principal engineer, and skips locked kinds. A rung change records a
  cutoff under the user-row lock (`User#record_level_changes`), except a move
  to principal engineer and the first-run track choice, which record none.
  Posted `LevelSuggestionStep`s whose `from` differs from the stored rung get
  a 409.
- **Skill level control** (`docs/decisions/skill-level-control.md`): Skill
  level choices are `KindDifficulty::LEVELS` (`User::SKILL_LEVELS`), edited
  only from Setup's Track select and the welcome page through `PATCH
  /profile`, which 422s anything outside the list. It sets the rung of every
  untargeted kind and never changes automatically. Under the user-row lock it
  clears targets per `TrackChange` and gives every kind it moves a cutoff and
  a `skill_level_edit` event row; it bumps `section_kind_preferences_version`
  only when it clears a target.
