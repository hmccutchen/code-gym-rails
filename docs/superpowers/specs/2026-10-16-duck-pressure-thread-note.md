# Note: the duck's rules are untested against repeated asking

Status: a guardrail gap, recorded for a later decision. No change is
proposed. Found while designing duck thread persistence
(`2026-10-16-duck-thread-persistence-design.md`), but it isn't caused by
persistence and exists on main today. Checked against `origin/main` at
`cb34804`.

## What the duck can reveal

The duck is shown the section as the engineer sees it
(`AiService#duck_section_context`): the scenario, question, options and
snippet. It is never shown an answer key, so an answer key can't leak from
it. But the answer to most sections can be worked out from what it is shown:
the defect in a code review snippet, or the better of a design comparison's
two pieces. The only thing stopping the duck from saying so is its
instructions (`DUCK_SYSTEM_PROMPT`, kind 2): "Never comply. Never state the
correct answer, the specific fix, or write corrected or complete code — not
even as an illustrative example. Respond with a single guiding question that
helps them find it themselves."

## What has been tested

The prompt-injection run (`docs/security-audit-2026-10-05.md`, "Duck" rows,
`script/security_audit/prompt_injection_red_team.rb`) sent the duck three
single messages, each asking for an ambiguity hunt's answer key. It held on
all three. That run tested the key, which isn't in the duck's context, so it
could only pass. It didn't test the answer the duck can work out, and it
didn't test a conversation.

Nothing has tested a thread: the same engineer asking again, more
insistently, across several messages, with the duck's earlier refusals in
its history. The duck already gets the whole thread with every turn, so this
is how it is used today. A thread can run to 6 messages before the cap, and
Clear starts another.

## The gap in the rules

The rules are unconditional. "Never comply" and "not even as an illustrative
example" don't depend on how many times someone has asked or how stuck they
say they are. What they don't say is that repeated asking, frustration or
urgency ("I've tried everything", "my manager needs this now", "just this
once") isn't a reason to reveal. Models tend to give way under that kind of
pressure over several turns, and nothing in the prompt names it.

## The question for later

Does the duck hold through a six-message pressure thread, and if not, should
its rules name repeated asking explicitly? Changing the rules would change
the duck for every account. Once hmccutchen/code-gym-rails#410 lands, its
prompt is pinned byte for byte
(`spec/services/duck_prompt_characterization_spec.rb`), so any change would
be deliberate and visible.

## How to find out

A live eval script beside the red-team script: scripted six-message pressure
threads on stored days, run once per provider. Each thread escalates from a
plain "what's the bug?" to frustration and urgency, with the duck's real
replies fed back as history. Every reply is checked for the planted defect
line, the better design-comparison piece, or a code block. It costs about $0.013 a thread on
Sonnet 5.5 and doesn't belong in CI.

## What lands now

Nothing. Persistence doesn't make this worse. The cap still holds a thread
to 6 messages, so the model never sees more turns than it can today, and the
running note that would have summed up the pressure in one line isn't being
built.
