// Design notes: docs/code-notes/app/javascript/code_gym/draft_store.md
const KEY = "code-gym-answer-draft"
const UNCONFIRMED_SAVES_KEPT = 5

function storage() {
  try { return window.localStorage } catch (_) { return null }
}

function read() {
  try { return JSON.parse(storage()?.getItem(KEY) ?? "null") } catch (_) { return null }
}

function write(draft) {
  try {
    storage().setItem(KEY, JSON.stringify(draft))
    return true
  } catch (_) {
    return false
  }
}

function clear() {
  try { storage()?.removeItem(KEY) } catch (_) { /* storage unavailable: nothing was kept */ }
}

function clearIf(matches) {
  const draft = read()
  if (draft && matches(draft)) clear()
}

function sortedEntries(object) {
  return Object.entries(object || {}).sort(([ a ], [ b ]) => (a < b ? -1 : a > b ? 1 : 0))
}

function canonicalDraft({ answers, ratings }) {
  return JSON.stringify([ sortedEntries(answers), sortedEntries(ratings) ])
}

export default class DraftCopy {
  constructor(token, scope) {
    this.token = token
    this.scope = scope
    this.unconfirmedSaves = []
    this.lastSent = null
    this.restored = null
    this.kept = false
  }

  restorable(rendered) {
    const draft = read()
    if (!draft || (draft.token !== this.token && !this.rendersUnconfirmedSave(draft, rendered))) {
      clear()
      return null
    }
    this.restored = draft
    return { answers: draft.answers, ratings: draft.ratings }
  }

  rendersUnconfirmedSave(draft, rendered) {
    if (draft.scope !== this.scope || !Array.isArray(draft.sent)) return false
    return draft.sent.includes(canonicalDraft(rendered))
  }

  takeOverUnconfirmedSaves() {
    const draft = this.restored
    if (draft?.scope !== this.scope || !Array.isArray(draft.sent)) return
    this.unconfirmedSaves = draft.sent.slice(-UNCONFIRMED_SAVES_KEPT)
  }

  store({ answers, ratings }) {
    this.kept = write({ token: this.token, scope: this.scope, sent: this.unconfirmedSaves, answers: answers, ratings: ratings })
  }

  recordSend(sending) {
    const sent = canonicalDraft(sending)
    this.lastSent = sent
    this.unconfirmedSaves = [ ...this.unconfirmedSaves.filter((earlier) => earlier !== sent), sent ].slice(-UNCONFIRMED_SAVES_KEPT)
    this.recordUnconfirmedSaves(sent)
  }

  recordUnconfirmedSaves(sent) {
    const stored = read()
    if (stored?.token !== this.token || stored.scope !== this.scope) return
    if (canonicalDraft(stored) !== sent) return
    this.kept = write({ ...stored, sent: this.unconfirmedSaves })
  }

  settle(replyToken, onScreen) {
    this.unconfirmedSaves = []
    if (typeof replyToken === "string") this.token = replyToken
    if (this.lastSent !== canonicalDraft(onScreen)) return true
    clearIf((stored) => canonicalDraft(stored) === this.lastSent)
    return false
  }

  clearOwn() {
    clearIf((stored) => stored.token === this.token)
  }

  discard() {
    clear()
  }
}

if (document.body?.dataset.signedOutPage !== undefined || document.querySelector("[data-submitted-day]")) clear()
