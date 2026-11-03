# `script/in_memory_usage.rb`

`InMemoryUsage.provider(base, usage) { |result, purpose| ... }` returns a
subclass of a provider service whose `log_usage` appends a row to `usage`
instead of writing an `ApiUsage` row, and whose `record_suggested_concept`
does nothing. A billed script builds its own subclass on top of it for its
other overrides (a pinned route, a read timeout, the prose judge turned off).

- **Why one place:** four scripts used to each define their own `log_usage`
  (#608). If `AiService#log_usage` changed its signature, every copy needed
  the same edit, and a missed one raised `ArgumentError` partway through a
  billed run. `spec/script/in_memory_usage_spec.rb` now fails if the
  parameters stop matching `AiService#log_usage`.
- **The row:** with no block it keeps input and output tokens
  (`InMemoryUsage.tokens`). A block builds a script's own row and runs on the
  service, so it can read the service's state, as `KeySampleDrafts` does for
  each call's cost and its spend cap.
- **Threads:** appends go through a lock, since
  `ConceptReferenceCalibration`'s concurrent mode calls the provider from
  several threads at once. The other three scripts call it from one thread.
- **Suggested concepts:** every script records none, since a run is a
  measurement. Today only a full draft (`ExerciseDraft.finish`) records one.
  `KeySampleDrafts` drafts through `retry_section`, and the calibration only
  calls `generate_concept_reference`; neither records one, so the stub
  changes nothing for them yet.
- **The guard's shape:** it compares parameter kinds plus keyword names, so a
  renamed `purpose:` fails it. Positional names aren't compared, since the
  override marks the unused user `_user`.
