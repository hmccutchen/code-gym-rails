# app/views/responses/bodies/_parsons_problem.html.erb

## Empty file

This partial is empty on purpose. A Parsons problem has no body distinct from
its answer: the block ladder is both the question and the answer control, so
it lives entirely in `responses/answers/_parsons_problem`. The section wrapper
still renders a body partial for every kind, passing the locals `data`,
`exercise`, `response` and `submitted`, so the file has to exist.

It holds no comment because a comment with no code after it breaks
`bin/comment-check`'s attachment rule.
