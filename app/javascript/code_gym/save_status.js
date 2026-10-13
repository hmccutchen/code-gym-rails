// Design notes: docs/code-notes/app/javascript/code_gym/save_status.md
import request from "code_gym/request"

const CARRIED = "code-gym-save-status-carried";
const RETRY_DELAYS_MS = [5000, 10000, 20000, 30000];

const failures = new Map();
const issued = new Map();
const queues = new Map();
let counter = 0;

let requests = 0;
const probes = [];

function generic() {
  return document.body?.dataset?.saveFailedText ?? "";
}

export function watch(probe) {
  probes.push(probe);
}

export function queued(key) {
  return (queues.get(key)?.waiting.length ?? 0) > 0;
}

export function pending() {
  return requests > 0 || [...queues.values()].some((line) => line.busy || line.waiting.length > 0) || probes.some((probe) => probe());
}

function render() {
  const banner = document.getElementById("save-status");
  const announcer = document.getElementById("save-status-announcer");
  if (!banner || !announcer) {
    document.addEventListener("DOMContentLoaded", render, { once: true });
    return;
  }
  const messages = Array.from(failures.values());

  if (messages.length === 0) {
    banner.hidden = true;
    banner.textContent = "";
    announcer.textContent = "";
    return;
  }

  banner.textContent = messages[messages.length - 1];
  announcer.textContent = banner.textContent;
  banner.hidden = false;
}

export function report(key, message) {
  failures.delete(key);
  failures.set(key, message);
  render();
}

export function clear(key) {
  failures.delete(key);
  render();
}

export function save(method, url, body, key, failureMessage = null) {
  const ticket = ++counter;
  issued.set(key, ticket);

  requests++;
  return request.send(method, url, body, { fallback: generic() }).then((result) => {
    if (issued.get(key) !== ticket) return { ok: false };
    if (failureMessage !== false) {
      if (result.ok) clear(key);
      else report(key, failureMessage || result.message);
    }
    return { ok: result.ok, status: result.status || undefined, data: result.data, unreached: result.status === 0, message: result.message };
  }).finally(() => { requests--; });
}

// A body given as a function is read when the save is sent; returning null drops that save.
export function queue(key, method, url, body, options) {
  const line = queues.get(key) ?? { busy: false, waiting: [] };
  queues.set(key, line);
  return new Promise((resolve) => {
    const last = line.waiting[line.waiting.length - 1];
    if (options?.latest && last) {
      last.body = body;
      last.resolvers.push(resolve);
    } else {
      line.waiting.push({ method: method, url: url, body: body, quiet: Boolean(options?.quiet),
                          offline: options?.offline ?? null, resolvers: [resolve] });
    }
    drain(key, line);
  });
}

async function drain(key, line) {
  if (line.busy || line.waiting.length === 0) return;
  line.busy = true;
  const next = line.waiting.shift();
  const result = await sendRetryingUnreached(key, next);
  line.busy = false;
  next.resolvers.forEach((resolve) => resolve(result));
  // A task, not a microtask: the reply's handlers update state the next save is built from.
  setTimeout(() => drain(key, line), 0);
}

function bodyOf(next) {
  try { return typeof next.body === "function" ? next.body() : next.body; } catch (_) { return null; }
}

async function sendRetryingUnreached(key, next) {
  for (let attempt = 0; ; attempt++) {
    const body = bodyOf(next);
    if (body === null) return { ok: false, skipped: true };
    const result = await save(next.method, next.url, body, key, next.quiet ? false : null);
    if (!next.offline || !result.unreached) return result;
    report(key, (typeof next.offline === "function" ? next.offline() : next.offline) || result.message);
    await connectionBack(attempt);
  }
}

function connectionBack(attempt) {
  return new Promise((resolve) => {
    const resume = () => {
      clearTimeout(timer);
      window.removeEventListener("online", resume);
      resolve();
    };
    const timer = setTimeout(resume, RETRY_DELAYS_MS[Math.min(attempt, RETRY_DELAYS_MS.length - 1)]);
    window.addEventListener("online", resume);
  });
}

export function carry(key, message) {
  try {
    sessionStorage.setItem(CARRIED, JSON.stringify({ key: key, message: message, path: location.pathname }));
  } catch (_) {
    // Private browsing can refuse the write; the reloaded page then just shows no message.
  }
}

function reportCarried() {
  try {
    const carried = sessionStorage.getItem(CARRIED);
    if (!carried) return;
    sessionStorage.removeItem(CARRIED);
    const parsed = JSON.parse(carried);
    if (parsed && parsed.message && parsed.path === location.pathname) report(parsed.key || "carried", parsed.message);
  } catch (_) {
    try { sessionStorage.removeItem(CARRIED); } catch (_) { /* storage is unavailable; the page shows no carried message */ }
  }
}

reportCarried();

export default { save, queue, queued, watch, pending, carry, report, clear };
