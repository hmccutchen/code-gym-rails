# `app/helpers/self_rating_helper.rb`

The self-rating wording moved here from `DailyResponse` (#588). The model keeps the facts: `SELF_RATINGS`, `#self_rating_for` and the favorable split.

## `#self_rating_labels`

The labels are read at render time, so the request's locale chooses the wording. `SectionStatusHelper#section_status` reads `#self_rating_label` too, and the dashboard's save reply reaches it through the controller's `helpers`.
