# Rubber-duck concept examples

An explicit request for a conceptual example, or explicit confusion about
an identifiable earlier explanation, can earn one small example in the
existing duck reply. It describes a different setting and reasoning
structure. The reply stays within the four-sentence explanation budget.
A reusable principle is optional. There is no automatic quiz or follow-up.

The first owner-controlled trial surfaced an unsolicited analogy, a
solving question after a concept-only answer, and six explanations that
exceeded four sentences. With examples enabled, the teaching trigger
governs analogies too. Only the learner's current message can make a
request mixed by asking for both understanding and solving help.
A safe concept-only reply explains the concept, includes one compact
event or state change when eligible, and stops. Keep any contrast
inside the example and add a principle only when it adds a new idea.

Pattern is the only kind that opts in. The active section and existing
day-wide concept withholding further restrict eligibility. Code Review
metadata can identify some modes. It cannot reliably tell whether an
example of visible code would expose the planted issue. Keep the existing
behavior for all excluded or unknown sections.
If a stored Pattern row has extra context that the general duck renderer
would include but Pattern does not surface, it keeps the original duck
prompt. This keeps the example grounded in visible Pattern prose.

The model must ground a term it introduced in visible behavior and a
genuine earlier assistant explanation in the current section's stored
history. A term or point label alone gives no permission. If a small
example would demonstrate the answer, bug, fix, missing step, correct
choice, or decisive reasoning, the duck uses its existing safe
explanation or guiding question. Ineligible and switch-off requests
retain their previous prompt bytes. The server gates the instruction
and enforces the existing context and call boundaries. Model outputs
still need a leakage check during the trial.

`DUCK_CONCEPT_EXAMPLES` is off unless the web process sees exactly `1`.
The flag is independent of `DUCK_NARROWING`. A direct teaching reply
adds no point label and interrupts the run of labelled questions.
Solving questions retain their existing narrowing behavior. The flag
does not add a provider call, change the six-turn limit, store new
metadata, or change generation, grading, mastery, or learner notes.
The example is stored as ordinary reply text, so existing transcript
readers can still see it under their current rules. Provider adapters
and their conversation framing stay the same.

## Local verification

Use the repository's test database and fake providers. These request and
prompt examples construct synthetic unsubmitted sets and stored turns,
exercise both switch states and narrowing, and never contact a live
provider. Keep the snapshot recorder variables unset.

```bash
env -u UPDATE_PROMPT_SNAPSHOTS -u UPDATE_REQUEST_SNAPSHOTS bundle exec rspec \
  spec/requests/responses_duck_concept_examples_spec.rb \
  spec/prompts/duck_prompt_spec.rb spec/prompts/duck_prompt_characterization_spec.rb \
  spec/clients/provider_request_characterization_spec.rb
bundle exec rspec spec/system/duck_thread_spec.rb
```

## Owner-controlled trial

Activate only after owner approval for an isolated web environment, route,
and budget. Begin with the Claude route and short unsubmitted Pattern
fixtures. Reserve ten eligible interactions and up to five setup asks to
create genuine earlier explanations. Count all submitted trial asks,
including failures, against the 15-ask ceiling. Keep one tab and avoid
manual retries, generation, submission, and extraction during the trial.
The 15 asks can make up to 45 transport attempts with existing retries.
At the recorded Claude rates, a budget assumption of 4,000 input tokens
and 400 output tokens per attempt estimates at most $0.63. Verify prices
and fixture sizes before activation. The 4,000 input tokens are a budget
assumption, so only an enforced provider limit can guarantee a ceiling.

Log one result per eligible interaction in encounter order with a local
identifier, trigger, and brief pass/fail observations. Include a qualifying
interaction where the duck omits the example. Track unsafe declined
requests separately. Keep transcripts out of the trial log.

1. Is the explanation clear?
2. Does the example help the learner understand the requested concept?
3. Can the learner explain it in their own words afterward? Mark this
   unobserved when they do not volunteer an explanation.
4. Is the example independent of the assessed solution?
5. Does it avoid unnecessary effort or pressure to keep responding?
6. Does it avoid revealing the answer or decisive reasoning?

More than two unclear or unhelpful results among the first ten triggers
reconsideration. **One answer leak or disclosure of decisive assessed
reasoning triggers immediate owner-controlled switch-off.** Confirm the
original prompt path returns. Record sparse eligibility and keep the
15-ask cap. The trial measures immediate understanding. Long-term retention
would require a delayed evaluation.
