# app/helpers/code_review_helper.rb

## Why a changed-lines label at all

A changed line is marked by a background and a left bar, both color. The label in each file's summary ("changed lines 3–5, 9") is the only other signal, for someone who can't tell the colors apart and for a screen reader, which doesn't announce a background, so it has its own helper spec.

Consecutive lines collapse into one range with an en dash, two lines included ("1–2"), and the numbers are sorted first. The words and the range format come from `sections.code_review.changed_lines` and `changed_range` in `config/locales/en.yml`, with the singular form for one line. A file with no changed line gets an empty label, and the summary shows only its path.
