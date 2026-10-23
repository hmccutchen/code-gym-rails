# app/javascript/controllers/copy_text_controller.js

Copies the setup key and the recovery codes. It talks only to the clipboard, never to the server, so it doesn't go through `CodeGymRequest`.

`navigator.clipboard` is missing outside a secure context, and `writeText` can be refused, for example from an installed iOS home-screen app. In either case the controller selects the source text with a `Range`, so it can be copied by hand, and says so in the status element, which is a polite live region. The messages come from `data-` values rendered from `config/locales/en.yml`.
