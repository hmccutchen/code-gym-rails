// Receives the daily reminder and shows it. Registered from the layout; served
// from the root path so its scope covers the whole app.

// Safari revokes a site's push permission outright if the worker takes a push
// and displays nothing, so every path through here ends in showNotification —
// a malformed or empty payload falls back to a generic notification rather
// than returning quietly and costing the user their subscription.
function readPayload(event) {
  try {
    return event.data ? event.data.json() : {}
  } catch (error) {
    return {}
  }
}

function notificationFor(event) {
  const payload = readPayload(event)
  const options = payload.options || {}

  return self.registration.showNotification(payload.title || "Code Gym", {
    body: options.body || "Today's set is ready.",
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    data: options.data || { path: "/" },
    tag: "daily-reminder"
  })
}

// includeUncontrolled, because a tab opened before this worker took control is
// still the window the user means — without it a second one opens alongside.
function focusOrOpen(path) {
  return clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
    for (const client of clientList) {
      if (new URL(client.url).pathname === path && "focus" in client) return client.focus()
    }

    return clients.openWindow ? clients.openWindow(path) : undefined
  })
}

self.addEventListener("push", (event) => {
  event.waitUntil(notificationFor(event))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const path = (event.notification.data && event.notification.data.path) || "/"
  event.waitUntil(focusOrOpen(path))
})
