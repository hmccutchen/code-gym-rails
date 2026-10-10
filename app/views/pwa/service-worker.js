// Safari revokes push permission if a push displays nothing, so a bad payload still ends in showNotification.
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

// includeUncontrolled finds a tab opened before this worker took control; without it a second one opens.
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
