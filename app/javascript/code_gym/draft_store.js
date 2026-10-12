// Design notes: docs/code-notes/app/javascript/code_gym/draft_store.md
const KEY = "code-gym-answer-draft"

function storage() {
  try { return window.localStorage } catch (_) { return null }
}

export function read() {
  try { return JSON.parse(storage()?.getItem(KEY) ?? "null") } catch (_) { return null }
}

export function write(draft) {
  try { storage()?.setItem(KEY, JSON.stringify(draft)) } catch (_) { /* refused write: the server's copy is the only one */ }
}

export function clear() {
  try { storage()?.removeItem(KEY) } catch (_) { /* storage unavailable: nothing was kept */ }
}

if (document.body?.dataset.signedOutPage !== undefined) clear()

export default { read, write, clear }
