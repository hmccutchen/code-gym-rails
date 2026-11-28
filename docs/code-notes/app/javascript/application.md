# app/javascript/application.js

The entry point publishes the shared request/save modules, starts Stimulus and
settles the bootstrap's early-edit record after the page's controllers have
connected. `controllersConnected` checks registered instances through the
existing Stimulus application, with a ten-second bound. Completion is not a
promise that missing modules loaded; callers still check their own controls.

`CodeGymBootstrap.controllersReady` exposes that same bounded wait for newly
appended exercise cards. The answer form refreshes its readiness gate afterward
and uses its existing missing-controls message when a controller is absent.
There is no recurring observer after the timeout and no additional network
request in this helper.
