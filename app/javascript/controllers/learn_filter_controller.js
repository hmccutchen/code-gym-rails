// Design notes: docs/code-notes/app/javascript/controllers/learn_filter_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "seenOnly", "empty", "entry", "block", "section"]

  apply() {
    const term = this.inputTarget.value.trim().toLowerCase()
    let shown = 0

    this.entryTargets.forEach((entry) => {
      const matchesTerm = entry.dataset.search.includes(term)
      const matchesSeen = !this.seenOnlyTarget.checked || entry.querySelector(".learn-seen") !== null
      const visible = matchesTerm && matchesSeen
      entry.hidden = !visible
      if (visible) shown++
    })

    this.blockTargets.forEach((block) => {
      block.hidden = this.entriesIn(block).every((entry) => entry.hidden)
    })
    this.sectionTargets.forEach((section) => {
      section.hidden = this.entriesIn(section).every((entry) => entry.hidden)
    })

    this.emptyTarget.hidden = shown > 0
  }

  entriesIn(element) {
    return [ ...element.querySelectorAll(".learn-entry") ]
  }
}
