# app/models/learner_item/merge.rb

The rules and their order are in `docs/decisions/learner-notes.md`.

## Why the lock comes first

Every writer of `learner_items` takes the user row lock before it reads, so
two merges for the same user run one after the other and the five-item cap
holds. Overdue open rows are expired under the same lock before any key is
compared, so an expired row never absorbs a new item.

## Repeats and new items are counted apart

After the reply collapses on its keys, a repeat of an open item can only add
a day to that item, so repeats have no limit beyond one per open item. Only
new items, closed-item repeats included, count toward the three a day.

## A unique violation is a merge

The partial unique index allows one open row per key. If a row for the key
appears between the read and the insert, the insert's savepoint rolls back
and the item is absorbed into that row instead.
