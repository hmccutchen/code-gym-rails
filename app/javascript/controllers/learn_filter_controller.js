// Design notes: docs/code-notes/app/javascript/controllers/learn_filter_controller.md
import { Controller } from "@hotwired/stimulus"

const EXACT = 3
const PREFIX = 2
const TYPO = 1
const PER_EDIT = 0.25
const ONE_EDIT_FROM = 5
const TWO_EDITS_FROM = 8

export default class extends Controller {
  static targets = ["input", "seenOnly", "empty", "entry", "block", "section"]

  connect() {
    this.entryWords = new Map(this.entryTargets.map((entry) => [ entry, this.words(entry.dataset.search) ]))
    this.pageOrder = new Map(this.entryTargets.map((entry, index) => [ entry, index ]))
    this.apply()
  }

  apply() {
    const query = this.words(this.inputTarget.value)
    const scores = new Map()

    this.entryTargets.forEach((entry) => {
      const score = query.length === 0 ? 1 : this.entryScore(query, this.entryWords.get(entry))
      const matchesSeen = !this.seenOnlyTarget.checked || entry.querySelector(".learn-seen") !== null
      entry.hidden = score === 0 || !matchesSeen
      scores.set(entry, score)
    })

    this.blockTargets.forEach((block) => {
      block.hidden = this.entriesIn(block).every((entry) => entry.hidden)
    })
    this.sectionTargets.forEach((section) => {
      section.hidden = this.entriesIn(section).every((entry) => entry.hidden)
    })

    this.emptyTarget.hidden = this.entryTargets.some((entry) => !entry.hidden)
    this.sortLists(query.length === 0 ? null : scores)
  }

  dismiss() {
    this.inputTarget.blur()
  }

  words(text) {
    const normalized = text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().replace(/\s*\+\s*/g, "+")
    return normalized.match(/[\p{L}\p{N}+]+/gu) || []
  }

  entryScore(query, entryWords) {
    let total = 0
    for (const queryWord of query) {
      const best = Math.max(0, ...entryWords.map((entryWord) => this.wordScore(queryWord, entryWord)))
      if (best === 0) return 0
      total += best
    }
    return total
  }

  wordScore(queryWord, entryWord) {
    if (entryWord === queryWord) return EXACT
    if (entryWord.startsWith(queryWord)) return PREFIX

    const allowed = this.allowedEdits(queryWord.length)
    if (allowed === 0) return 0
    const edits = this.prefixDistance(queryWord, entryWord)
    return edits <= allowed ? TYPO - edits * PER_EDIT : 0
  }

  allowedEdits(length) {
    if (length < ONE_EDIT_FROM) return 0
    return length < TWO_EDITS_FROM ? 1 : 2
  }

  // Damerau-Levenshtein to the closest leading part of the entry word, so a swap counts as one edit even beside another.
  prefixDistance(queryWord, entryWord) {
    const far = queryWord.length + entryWord.length
    const d = Array.from({ length: queryWord.length + 2 }, () => new Array(entryWord.length + 2).fill(far))
    for (let i = 0; i <= queryWord.length; i++) d[i + 1][1] = i
    for (let j = 0; j <= entryWord.length; j++) d[1][j + 1] = j
    const lastRowOf = new Map()
    for (let i = 1; i <= queryWord.length; i++) {
      let lastMatchColumn = 0
      for (let j = 1; j <= entryWord.length; j++) {
        const k = lastRowOf.get(entryWord[j - 1]) || 0
        const l = lastMatchColumn
        const cost = queryWord[i - 1] === entryWord[j - 1] ? 0 : 1
        if (cost === 0) lastMatchColumn = j
        d[i + 1][j + 1] = Math.min(d[i][j] + cost, d[i + 1][j] + 1, d[i][j + 1] + 1,
          d[k][l] + (i - k - 1) + 1 + (j - l - 1))
      }
      lastRowOf.set(queryWord[i - 1], i)
    }
    return Math.min(...d[queryWord.length + 1].slice(2))
  }

  sortLists(scores) {
    const lists = new Set(this.entryTargets.map((entry) => entry.parentElement))
    lists.forEach((list) => {
      const entries = this.entryTargets.filter((entry) => entry.parentElement === list)
      entries.sort((a, b) => this.rank(b, scores) - this.rank(a, scores) || this.pageOrder.get(a) - this.pageOrder.get(b))
      list.append(...entries)
    })
  }

  rank(entry, scores) {
    if (scores === null) return 0
    return entry.hidden ? -1 : scores.get(entry)
  }

  entriesIn(element) {
    return [ ...element.querySelectorAll(".learn-entry") ]
  }
}
