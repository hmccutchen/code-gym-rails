# spec/requests/dashboard_spec.rb

## Glossary: "leaves a term not present in the curated glossary as plain text"

The example builds its own problem set instead of using `base_problem_set`, because that set's "Service Objects" title would itself match a glossary entry.

## Glossary: "leaves a section's title unwrapped"

A glossary term inside a section's summary would nest an interactive control inside the control that folds the section, so titles stay unwrapped while body text is still wrapped.

## "mobile section gutter"

The example parses the layout's `.section` rules and fails if one of them sets its own `margin-inline`, so the layout can't give sections a second break-out beside the shared one. The shared break-out lives in `phone_cards.css`, and `spec/views/container_gutter_spec.rb` pins its declarations.

## Structure diagrams: `data-owns-details`

The attribute tells a failed render's cleanup that it may remove the `<details>` element this partial created.

## Size forecast: "counts today's submission toward tomorrow's completion"

Without today's submission, the history holds only two days, which is too few for the completion rule; the rule then gives the largest day.
