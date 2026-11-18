# app/controllers/account_learner_items_controller.rb

Both actions run without `require_provider`, so an account that removed its
key, or a house-key account that still has rows, can still close and delete
them. Neither needs `LEARNER_NOTES`: the section shows while the account has
rows, so its buttons must work with the switch off.

`LearnerItem.dismiss!` and `.remove!` take the user row lock and look the item
up through the account's own rows, so another account's id answers as
missing. "I've got this" dates the close in the owner's zone, since retention
and the `returned_after` line read that date as the owner's day.
