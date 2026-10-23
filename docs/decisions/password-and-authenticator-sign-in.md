# Password and authenticator sign-in (superseded)

Superseded by `docs/decisions/passwordless-sign-in.md`.

#490 replaced the emailed sign-in code with Devise:
- a password plus a code from an authenticator app, which was mandatory;
- open sign-up with email confirmation;
- emailed password resets.

It was live for about a day. #491 reverted it. Sign-in is the emailed code again, with no password column, and an authenticator becomes an optional second factor in a later PR. The new decision doc gives the reasons.

The full text of this doc as #490 wrote it is in the repository history at `c7a500c0`.
