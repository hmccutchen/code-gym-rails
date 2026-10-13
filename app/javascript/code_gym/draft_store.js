// Design notes: docs/code-notes/app/javascript/code_gym/draft_store.md
const KEY = "code-gym-answer-draft"

function storage() {
  try { return window.localStorage } catch (_) { return null }
}

export function read() {
  try { return JSON.parse(storage()?.getItem(KEY) ?? "null") } catch (_) { return null }
}

export function write(draft) {
  try {
    storage().setItem(KEY, JSON.stringify(draft))
    return true
  } catch (_) {
    return false
  }
}

export function clear() {
  try { storage()?.removeItem(KEY) } catch (_) { /* storage unavailable: nothing was kept */ }
}

export function clearIf(matches) {
  const draft = read()
  if (draft && matches(draft)) clear()
}

if (document.body?.dataset.signedOutPage !== undefined || document.querySelector("[data-submitted-day]")) clear()

export default { read, write, clear, clearIf }
