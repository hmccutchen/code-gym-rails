// Design notes: docs/code-notes/app/javascript/code_gym/push.md
import request from "code_gym/request"

// Test capability, never the OS version: iOS hides PushManager outside a Home Screen app.
export function supported() {
  return "Notification" in window && "serviceWorker" in navigator && "PushManager" in window
}

export function failure(text) {
  const error = new Error(text)
  error.readable = true
  return error
}

function applicationServerKey(base64) {
  const padded = (base64 + "=".repeat((4 - (base64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/")
  const raw = window.atob(padded)
  return Uint8Array.from(raw, (character) => character.charCodeAt(0))
}

async function subscribeReplacingAnotherKey(pushManager, key) {
  const options = { userVisibleOnly: true, applicationServerKey: key }
  try {
    return await pushManager.subscribe(options)
  } catch (error) {
    const existing = error.name === "InvalidStateError" && await pushManager.getSubscription()
    if (!existing) throw error

    await existing.unsubscribe()
    return pushManager.subscribe(options)
  }
}

// A 4xx and an expired session's redirect to /login must both reject, or a failed enrolment looks saved.
async function register(subscription, { registerPath, registerFailedText }) {
  const json = subscription.toJSON()
  const result = await request.send("POST", registerPath, {
    endpoint: json.endpoint,
    p256dh: json.keys.p256dh,
    auth: json.keys.auth
  }, { fallback: registerFailedText })
  if (!result.ok) throw failure(result.message)

  return result
}

// subscribe() returns the existing subscription for the same key, so this doubles as "get the current endpoint".
export async function subscribeAndRegister({ vapidKey, registerPath, knownEndpoints, registerFailedText }) {
  await navigator.serviceWorker.register("/service-worker.js")
  const registration = await navigator.serviceWorker.ready
  const subscription = await subscribeReplacingAnotherKey(registration.pushManager, applicationServerKey(vapidKey))
  if (knownEndpoints.indexOf(subscription.endpoint) !== -1) return null

  return register(subscription, { registerPath, registerFailedText })
}

export default { supported, failure, subscribeAndRegister }
