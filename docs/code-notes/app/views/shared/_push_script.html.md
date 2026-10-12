# app/views/shared/_push_script.html.erb

## The partial as a whole

The layout renders this partial on every page. For an enrolled user
(`push_reminders_enabled?`) it mounts the `push-launch` controller with the
settings `PushHelper#push_settings_data` builds; for anyone else it renders
nothing. The plumbing it used to define inline now lives in
`app/javascript/code_gym/push.js`, which both push controllers import, so
nothing on the page depends on this partial running first.

It never requests notification permission. That call has to happen
synchronously inside a real click, which only the Account page's
`push-enable` controller handles.

## Where the rest is explained

Re-subscribing on launch and its silent failures:
`docs/code-notes/app/javascript/controllers/push_launch_controller.md`.
Registration and why a redirect or a 4xx counts as failure:
`docs/code-notes/app/javascript/code_gym/push.md`.
