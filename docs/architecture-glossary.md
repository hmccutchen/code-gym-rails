# Architecture glossary

Names for the modules that architecture reviews have found or created. This
file is separate from `app/models/glossary.rb`, which holds the programming
terms the app shows on hover.

## ConceptVocabulary

The closed concept lists and the questions asked of them
(`app/models/concept_vocabulary.rb`).

## Claimable

The claim on a paid provider call that a review or a regeneration holds while
it runs (`app/models/concerns/claimable.rb`).

## ResponseReview

Applying a review to a submitted response, from taking the claim to recording
mastery (`app/services/response_review.rb`).

## ReviewGrading

The review fan-out and the rules applied to each graded section
(`app/services/review_grading.rb`).

## CodeGymAnswerRules

The browser's copy of the answer, submit-gate and section-status rules
(`app/views/shared/_answer_rules.html.erb`), held to the Ruby rules by a parity
spec.
