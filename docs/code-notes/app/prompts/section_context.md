# `SectionContext`

Moved out of `AiService` (#451), where it was `#duck_section_context`. The duck and the difficulty assessment both describe a section with it. It names each field it shows, so answer-key fields never reach either prompt.

## `.parsons_blocks`

Stored blocks are already in the solved order, so positions come only from a
persisted scramble; without one the blocks are listed unordered. Each block
goes through `to_s` before sorting, because a provider can return non-strings
and sorting mixed types raises.

## `.scrambled_display_order`

The identity permutation means no scramble was persisted. Echoing it would
present the solution as the learner's order.
