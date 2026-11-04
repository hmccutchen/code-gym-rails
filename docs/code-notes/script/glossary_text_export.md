# `script/glossary_text_export.rb`

`GlossaryTextExport` writes the text the glossary check in #578 needs, one
JSON object per line with `source`, `id`, `field` and `text`, the shape
`script/glossary_sense_listing.rb` reads. `script/export_glossary_text.rb`
runs it and sends the lines to stdout.

- **What it reads:** the stored review and exercise text the pages pass
  through `glossary_wrap`. Concept reference, recognition guide and lesson
  text is wrapped too, but #578 covers review and exercise text only.
  - **Reviews** (`source: "review"`, `id` `<response>:<section>`): each
    `DailyResponse::AI_REVIEW_FIELDS` point, the difficulty reason and every
    saved alternate explanation.
  - **Exercises** (`source: "exercise"`, `id` `<exercise>:<section>`): the
    scenario, question, architecture options, the architecture inline
    reference's tagline, explanation, tradeoffs and senior lens (`reference_*`
    fields), ambiguity hunt request,
    pseudocode problem statement, pattern `why` and plan review
    `plan_excerpt`. A spec fixture holds every one, so a field the export
    drops fails it. It reads every `problem_set` key, alternates the page
    doesn't show included, which only adds text to check.
- **What it leaves out:** the answer, rating, answer key and user columns. It
  loads only the columns it reads. Generated text can still quote an
  engineer's answer or use their name, so the file stays private and is
  deleted after the listing is read.
- **Safety:** it reads inside `ReviewBaselineExport.read_only`, so a write
  would fail rather than land.
- **The listing:** to check every existing glossary key against this text,
  run the listing with an empty base-words file, so nothing counts as
  already reviewed.
