// Design notes: docs/code-notes/app/javascript/controllers/glossary_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  click(event) {
    this.toggleTerm(event.target.closest(".gloss-term"))
  }

  key(event) {
    if (event.key !== "Enter" && event.key !== " ") return

    const term = event.target.closest(".gloss-term")
    if (!term) return

    event.preventDefault()
    this.toggleTerm(term)
  }

  reposition(event) {
    const term = event.target.closest && event.target.closest(".gloss-term")
    if (term) this.positionPanel(term)
  }

  repositionOpen() {
    const open = this.element.querySelector(".gloss-term.gloss-open")
    if (open) this.positionPanel(open)
  }

  toggleTerm(term) {
    this.element.querySelectorAll(".gloss-term.gloss-open").forEach((el) => {
      if (el !== term) el.classList.remove("gloss-open")
    })
    if (term && term.classList.toggle("gloss-open")) this.positionPanel(term)
  }

  positionPanel(term) {
    const box = term.closest(".section, .container")
    if (!box) return

    const rect = box.getBoundingClientRect()
    const pad = parseFloat(getComputedStyle(box).paddingLeft) || 0
    term.style.setProperty("--gloss-width", `${rect.width - pad * 2}px`)
    term.style.setProperty("--gloss-shift", `${rect.left + pad - term.getBoundingClientRect().left}px`)
  }
}
