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

## Domains

Examples spread across gym, grocery and library settings, plus one Code Gym
feature request (the ambiguity hunt draws its requests from Code Gym) and one
room booking, so no single setting starts to stand for the app.
