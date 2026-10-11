// Design notes: docs/code-notes/app/javascript/code_gym/request.md
function text(name) {
  return document.body?.dataset?.[name] ?? "";
}

function csrf() {
  return document.querySelector('meta[name="csrf-token"]')?.content ?? "";
}

async function read(response) {
  try { return await response.json(); } catch (_) { return null; }
}

// Rails' own error JSON carries a numeric status, so only the app's replies pass.
function appMessage(data) {
  return data && typeof data.status === "string" && typeof data.error === "string" ? data.error : null;
}

export async function send(method, url, body, options) {
  const fallback = options?.fallback ?? "";
  const headers = { "Accept": "application/json", "X-CSRF-Token": csrf() };
  const init = { method: method, headers: headers };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }

  let response;
  try {
    response = await fetch(url, init);
  } catch (_) {
    return { ok: false, status: 0, data: null, message: fallback, signedOut: false };
  }

  // The only redirect a JSON endpoint gives is to the login page after the session expires.
  if (response.redirected) {
    return { ok: false, status: response.status, data: null, message: text("signedOutText"), signedOut: true };
  }

  const data = await read(response);
  if (response.ok) return { ok: true, status: response.status, data: data, message: null, signedOut: false };
  return { ok: false, status: response.status, data: data, message: appMessage(data) || fallback, signedOut: false };
}

export function get(url, options) {
  return send("GET", url, undefined, options);
}

export default { send, get };
