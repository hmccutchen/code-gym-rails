# app/models/section_kind_guide.rb

## Why a module, not a method on each kind

The `ExerciseSection` classes are read by `AiService` to build prompts. Copy
written for a person sits apart from them so a later change cannot pass it
into a prompt by accident. The cost is that a new kind needs an entry here as
well as its class; `spec/models/section_kind_guide_spec.rb` fails until it has
one, the same way a missing `sections.<key>.name` locale string shows up.

## Why the copy lives in Ruby, not the locale file

Locale strings are not checked. Text in a module listed in
`HandWrittenLearnText::MODULES` runs through the plain-language spec.

## Examples never give an answer

Each example says what the engineer sees and what they are asked. The
ambiguity hunt example names no gap and no kind of gap: the kinds of gap the
generator plants are listed only inline in the prompt
(`ExerciseSection::AmbiguityHunt.generation_guidance`), not as a constant a
spec could read, so a reviewer checks this one by eye.

## The one-line `short`

A daily card's swap sheet lists all ten kinds, so each row needs one line,
not the two-sentence summary. Cutting the summary short would end sentences
mid-thought, so each kind has its own `short` line, written to fit the 304 px
a row's second line has at a 390 px viewport. A line that runs over wraps
rather than being cut.

Several words in these lines are deliberate. Keep them when editing:

- **Code Review says "problem", not "bug".** The day's code is sometimes a
  test file or a database migration, where the issue isn't a bug.
- **Design Comparison says both pieces work, and "suits the system".** That
  both work separates it from Code Review, and the choice is about which
  design fits the system described, not which is better in general. The
  line is 2 px over the row at 390 px and wraps there on purpose. Dropping
  "work" to make it fit would lose the distinction.
- **Plan Review says "flaws".** Every plan carries 2-3 planted flaws (an
  anti-pattern, scope creep, an unflagged behaviour change), most of them
  things the plan does rather than omits, so "misses" would be wrong.
  "Flaws" also keeps it apart from Code Review's "problem", and avoids
  "push back on", which presumes the plan is wrong before it is read.
- **Pseudocode to Code says "see the code".** The engineer writes only the
  steps, and Code Gym turns them into code at review. "Then in code" would
  say the engineer writes the code too.
- **Parsons Problem says "pieces", not "lines".** A block can hold more
  than one line.
- **Pattern of the Month says "a named pattern".** The kind's name already
  supplies "design".
- **The Ambiguity Hunt line names no gap,** like its example.
- **No line uses a semicolon.**

The spec requires one sentence with no semicolon, and `.learn_text` offers
the lines to the plain-language checks.

## Domains

Examples spread across gym, grocery and library settings, plus one Code Gym
feature request (the ambiguity hunt draws its requests from Code Gym) and one
room booking, so no single setting starts to stand for the app.
