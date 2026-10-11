# app/javascript/controllers/learn_filter_controller.js

## What it owns

The Learn index's filter: the text box, the "seen in your sets" checkbox, the
per-entry hiding, and the empty state.

## The controller element wraps the filter and the list

Entries are not descendants of the filter controls, so the controller mounts on
a wrapper enclosing both. Stimulus targets must be inside the controller
element, and the groups and buckets have to be reachable to hide an emptied
one.

## It matches a rendered attribute

Each entry carries `data-search` holding the text actually shown on screen.
Matching against the raw concept key instead would make typing the visible
label find nothing, which `spec/system/learn_filter_spec.rb` exists to catch.

## Groups and buckets hide with their contents

A group whose every entry is hidden is hidden itself, and so is a bucket whose
groups are all empty. Otherwise a filtered page shows headings over nothing.

## connect() applies the filter

A term typed, the checkbox ticked, or either restored by the browser on Back
before the controller connects reaches no action, so the controls would show a
filter the list does not. `connect()` runs `apply()` once so the list always
matches the controls. `spec/system/deferred_module_spec.rb` stalls this
controller's module, types a term, and expects the list filtered once it
connects.
