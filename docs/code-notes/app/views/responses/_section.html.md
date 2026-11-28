# app/views/responses/_section.html.erb

The shared section card keeps its heading, native disclosure, server-rendered
status and existing concept/reference withholding. Unsubmitted practice uses
the kind name and optional title without an ordinal; submitted Today and
History retain numbered labels. The slot remains available for layout and
stored ordering, independently of the visible heading.

Rating buttons keep their pressed state and shared delegated action. Clicking
the selected draft rating clears it through the answer form controller;
submitted cards render no rating controls.
