# app/jobs/generate_additional_exercise_job.rb

## One accepted operation

The job names an ExerciseAddition ID, runs in its owner's time zone and uses
the account-deletion guard. It holds the exercise advisory lock through claim,
capture, provider work and commit. Only an unexpired queued operation that
has never claimed execution can start. Redelivery never takes over a running
operation or repeats its uncertain provider attempt.

The ordinary generation pipeline receives the requested kind and captured
context. It retains the existing generation deadline, provider retry budgets,
judges, ingest checks and answer-key protection. `PracticeGeneration` performs
the final identity and capture checks and atomically appends the accepted
section. A superseded result fails the matching operation without buying an
automatic replacement. Explicit learner retry creates a new operation; it
can incur another charge if a previous provider reply was lost.

## Failure status and key holds

The job records the provider/key identity before capture and provider setup.
A ProviderError or SetupError fails the matching claim, then reports the
failure through `User#report_call_failure` under the owner lock. A changed key
or stale claim cannot replace the current account's failure status.

Manual Add failures use `counts_toward_key_hold: false`, as regeneration does.
Only automatic daily generation counts toward the key hold. Add success does
not reset that counter. An all-sections-rejected result fails the operation
without recording an account/key failure; its quality checks do not establish
that the credential is bad. Unexpected errors release the matching operation
and remain visible to job infrastructure, but a later execution still cannot
replay the provider attempt.
