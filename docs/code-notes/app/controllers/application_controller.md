# app/controllers/application_controller.rb

## `#require_login` and `#page_navigation?`

Every signed-out request is redirected to `/login`, whatever its format. `request.js` reads that redirect as "signed out", so a JSON endpoint must not answer with a 401 instead.

The return address is saved only for a page navigation: a GET whose `Accept` names `text/html`. Saving it for any request let an expired dashboard poll (`GET /dashboard/status`, `Accept: application/json`) become the page the next sign-in landed on.

`request.format.html?` isn't the test, because in Rails 8.1.4 it's true for more than page loads:

| `Accept` | `format.html?` |
|---|---|
| `*/*` | false |
| none | true |
| any list ending in `*/*`, such as an image request's `image/avif,image/webp,*/*` | true |

Rails treats a browser-style `Accept` list as HTML. Only a navigation names `text/html`. `spec/requests/require_login_spec.rb` pins each case, and its image example is the one that fails under `format.html?`.
