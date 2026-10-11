# app/views/shared/_answer_rules.html.erb

The browser's copy of the rules for whether an answer counts and whether the
day can be submitted. The page needs them on every keystroke, so they can't
wait for a server round trip, but the server's rules decide.
`spec/system/answer_rules_parity_spec.rb` runs one table of cases through each
Ruby rule and its counterpart here and fails on any disagreement:

- `proseAnswered`: `ExerciseSection.answered?` with `substantive_answer`
- `comparisonAnswered`: `ExerciseSection::DesignComparison.answered?`
- `submitBlocker`: `DailyResponse#submit_blocker`
- `sectionStatus`: `SectionStatusHelper#section_status`

Every constant (the length floor, the reason minimum, the pieces, both answer
prefixes) is rendered in from Ruby rather than copied.

## `strip`

Ruby's `String#strip` removes only ASCII whitespace and NUL, while
`String.prototype.trim` also removes Unicode spaces such as a non-breaking
space. Using `trim` here made an answer padded with non-breaking spaces count
differently in the browser than on the server; the parity table has those
cases.

## Where it is rendered

At the top of `dashboard/_exercise`, before the answer form. The layout renders
its shared scripts at the end of `<body>`, after a page's inline scripts have
run, and the answer controls read this object while the page loads.
