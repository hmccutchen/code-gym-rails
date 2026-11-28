# app/models/daily_kind_swap/consequences.rb

The swap picker describes how a preference change affects future recommendations.
It leaves the current exercise unchanged and promises neither a particular next
kind nor a larger future workload.

The pure object takes the pair, place, incoming kind, `KindPreferences`, and
practice-policy display status. The picker reads those inputs once per card.
Stored daily counts, historical set size and capacity brakes do not affect
future recommendation wording.

`sentences` describes the incoming kind's stored weight, exclusion and fourth
pool restrictions. `warning` describes the outgoing kind. An unavailable
practice-policy read suppresses prediction. A fourth replacing a fourth keeps
the existing pool restriction; a stored outgoing exclusion remains effective.
Otherwise the outgoing kind remains eligible for future recommendations.

A single exercise cannot share a concept with another planned section, so the
old pair-sharing calculation and same-day promise are removed. Historical sets
keep their own content and recorded pair.
