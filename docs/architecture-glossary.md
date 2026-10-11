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

## ReviewGrading

The review fan-out and the rules applied to each graded section
(`app/services/review_grading.rb`). Its reasoning is in
`docs/code-notes/app/services/review_grading.md`.

## CodeGymRequest

The one way a page script sends a request (`app/javascript/code_gym/request.js`):
it reads the CSRF token, recognises an expired session, and decides what a
failure may show. `CodeGymSaveStatus.queue` sends a control's saves one at a
time on top of it, and `JsonErrors#render_json_error` is the server's half of
the contract. Its reasoning is in `docs/code-notes/app/javascript/code_gym/request.md`.
