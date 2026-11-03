# `script/glossary_text_export.rb`

`GlossaryTextExport` writes the text the glossary check in #578 needs, one
JSON object per line with `source`, `id`, `field` and `text`, the shape
`script/glossary_sense_listing.rb` reads. `script/export_glossary_text.rb`
runs it and sends the lines to stdout.

- **What it reads:** everything the pages pass through `glossary_wrap` from
  stored rows.
  - **Reviews** (`source: "review"`, `id` `<response>:<section>`): each
    `DailyResponse::AI_REVIEW_FIELDS` point, the difficulty reason and every
    saved alternate explanation.
  - **Exercises** (`source: "exercise"`, `id` `<exercise>:<section>`): the
    scenario, question, architecture options, ambiguity hunt request and
    pseudocode problem statement.
- **What it leaves out:** answers, ratings, answer keys and any user detail,
  so the file can be read by whoever runs the listing.
- **Safety:** it reads inside `ReviewBaselineExport.read_only`, so a write
  would fail rather than land.
- **The listing:** to check every existing glossary key against this text,
  run the listing with an empty base-words file, so nothing counts as
  already reviewed.
