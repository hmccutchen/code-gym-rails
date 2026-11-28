# app/javascript/controllers/exercise_addition_controller.js

## Picker and request identity

The Add picker uses the Swap sheet's presentation with separate actions. It
posts one chosen kind and never changes permanent preferences. Server state
controls the available options. Posting, active generation and an inert
answer form disable Add; a submitted reply hides the trigger.

One in-memory UUID identifies an acceptance request. Repeated taps cannot
start another POST. If transport never returns a reply, retry keeps the UUID
and kind so the server can replay the accepted operation. A received failure
ends that attempt; the next explicit request gets a fresh UUID. A reload
reconstructs durable operation state from the server rather than persisting a
second client operation ledger.

## Read-only status and inserted cards

Polling carries the form's scope and manifest revision. A request ticket
ignores older responses; scope and revision checks reject replies for another
set or an older structure. Active work keeps polling, and focus or visibility
can refresh a terminal page. Polling never recovers or changes operations.
Expiry is displayed as a retryable failure, with recovery left to a mutation.
Disconnect cancels the timer and listeners.

`answer_form#reconcileStructure` inserts only missing cards. The Add controller
never replaces existing inputs, ratings, folds or duck text. Newly inserted
cards adopt their server-computed answered state and rendered rating; existing
live cards keep their own state. The insertion event initializes diagrams and
code-width observation through their existing controllers.

The controller uses the shared request and save-status modules. A manifest
conflict or active-operation refusal refreshes structure without dropping
drafts or automatically submitting. The server remains responsible for
ownership, eligibility, request limits and submission safety.
