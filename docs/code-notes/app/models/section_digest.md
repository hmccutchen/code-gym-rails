# app/models/section_digest.rb

`SectionDigest.call(section)` is the SHA-256 of a section hash's canonical
JSON: keys are stringified and sorted at every depth, and array order is
kept. Two hashes holding the same section in different key orders get the
same digest, and any change to a value, nested ones included, gives a
different one.

It's a module of its own rather than a method on `JudgeSolve`, so the
service-layer `JudgedGeneration::Solve` can compute the same value without
naming the model, and the model doesn't name the service.

What the digest is used for, and why it never decides `shipped`, is in
`docs/code-notes/app/models/judge_solve.md` under "Why the digest isn't used
for `shipped`".
