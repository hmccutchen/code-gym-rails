# One "answered" authority

`DailyResponse.answered?` delegates completion
to the section kind. Prose needs any text left after untouched scaffold
labels are removed. A design comparison needs a valid pick or a non-blank
reason. Parsons instead needs an explicitly saved complete permutation of its
stored blocks, regardless of encoded length. One- and two-block exercises
are supported; the generation prompt's five-to-eight target is not an
ingest bound. An untouched control stays unanswered. Moving a block records
the arrangement. A one-block exercise has nothing to move, so only it shows a
"Use this order" button; with two or more blocks the scramble never starts in
the correct order and every move already saves. The browser holds no copy
of these rules. The page starts from the server's answered sections and
submit blocker, rendered on the form, and every autosave reply and refused
submit carries them again (`answered_sections`, `submit_blocker`). Progress,
the hint lock, the status lines and the nudge show the latest reply.
History, mastery and generation ask the same authority.

`DailyResponse#answer_for` delegates review/display representation to the
kind too. A short answer such as "add index" is shown, graded and needs a
self-rating like any other. Only a blank or scaffold-only section shows
"(skipped)". A design comparison pick with no reason, or a reason with no
pick, is shown as written. Parsons preserves malformed attempts
for its strict local grading and lenient read-only replay, so a corrupt id
cannot hide the other blocks the engineer arranged; it does not count as
completed work. Calibration mismatch notes require completion.

**The 10-character floor was removed on 2026-10-27.** Issue #178 added
`ANSWER_MIN_LENGTH`, so prose needed more than 10 characters after the scaffold
labels came off, and a shorter answer such as "add index" counted as skipped.
It went because a short answer is still an answer: the engineer wrote it, so it
is graded, needs a self-rating, counts toward completion and feeds mastery
evidence. The design comparison rule moved the same way, so a pick with no
reason and a reason with no pick are both answers. Only a blank or
scaffold-only section is unanswered, and it gets an ungraded walkthrough
(`docs/decisions/grading-rubric.md`). The partial-answer code that carried a
too-short note through the review, and its "Not counted as an answer." label,
was deleted with the floor, since nothing is both unanswered and written.
