# Architecture glossary

Names for the modules that architecture reviews have found or created. This
file is separate from `app/models/glossary.rb`, which holds the programming
terms the app shows on hover.

## ConceptVocabulary

The closed concept lists and the questions asked of them
(`app/models/concept_vocabulary.rb`). Its reasoning is in
`docs/code-notes/app/models/concept_vocabulary.md`.

## Claimable

The claim on a paid provider call that a review or a regeneration holds while
it runs (`app/models/concerns/claimable.rb`). Its reasoning is in
`docs/code-notes/app/models/concerns/claimable.md`.

## ResponseReview

Applying a review to a submitted response, from taking the claim to recording
mastery (`app/services/response_review.rb`). Its reasoning is in
`docs/code-notes/app/services/response_review.md`.
