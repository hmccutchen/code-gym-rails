# Waiting retention checks

`DailyPlan` reads due checks for every bucket
in the user's slice, plus the bucket of the language being generated, in
one query (`User#concepts_due_for_retention_check_in`), including
architecture and the fourth buckets, which were fetched only when their
kind was chosen and so waited with no trace on every other day. The
generated language is added because a regeneration keeps the stored
exercise's language, which can differ from the setting. That one read also feeds
both tracks' retention checks, which filter it by bucket instead of
querying each bucket again, and `ConceptMastery.due_for_retention_check`
is the one statement of what "due" means. A check is selected, and a slot
reserved for an overdue one, only when some section today can tag it, by
the same `DayHosts` test the waiting classification uses: on a
schema-review two-section day a core Ruby check that neither fixed section
can tag waits as `no_host`, where the coverage exception can bring it a
host, rather than being selected and then left out of the prompt. Each
check the plan did not offer and reinforcement does not carry lands on
`Result#waiting_checks` with a reason: `no_slot` when a section today
could tag it but the hosts went elsewhere, `no_host` when none could.
Generation logs them on one line beside the other two:
`[retention] user=… date=… waiting=bucket:concept(no_slot|no_host),…`.
