# app/views/responses/answers/_pseudocode_to_code.html.erb

## The partial as a whole

The textarea and the critique control both live in this one partial, for both states. The submitted state must still show the critique and the code the plan was translated into at review time, because those are what the review was graded against.

## Generated code caption

The caption is load-bearing copy. Without it the generated code reads as a model answer, which is the misreading the faithfulness constraint exists to prevent.
