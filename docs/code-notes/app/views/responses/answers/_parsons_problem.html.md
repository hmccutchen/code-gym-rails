# app/views/responses/answers/_parsons_problem.html.erb

## The partial as a whole

This is the answer area for `parsons_problem`, in both states. Unlike every other kind, the stored answer is a positional order rather than prose. A submitted section therefore replays the blocks in the order the engineer arranged them, marking each correct or misplaced, instead of echoing `order:0,2,1`.

## Submitted replay

The replay uses `parse_order`, not `submitted_order`. Grading rejects anything short of a complete permutation, but this view replays what the engineer arranged, and showing every block as "(skipped)" because one id is corrupt would hide work they did do. The rule is strict at the boundary and lenient in the UI.

## Initial order

The engineer's own saved arrangement wins over the original scramble, so a reload doesn't undo their work. `initial_order` rejects each candidate unless it is a complete permutation of the blocks, so a corrupted answer or a row missing `display_order` falls back rather than dropping blocks.

## Keyboard hint

The hint stays clipped until a block takes focus, which keeps it out of the way of people who drag with a pointer and never need it.

## Reorder script

Neither the drag path nor the up/down buttons sync the hidden field on wire-up. They sync only on a move or an explicit confirmation, so the section reads as unanswered until the engineer does something, the same as every other section.

## SortableJS import

The version is pinned exactly, the same posture as the Mermaid import in `shared/_mermaid_diagram`. A blocked CDN falls back to the injected up/down buttons.

The `delayOnTouchOnly` hold exists because, without the arrow buttons, touch dragging is the only input on a phone; the hold lets an ordinary swipe scroll the page instead of picking up a block. Mouse dragging is unaffected.
