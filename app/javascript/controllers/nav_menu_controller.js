// Design notes: docs/code-notes/app/javascript/controllers/nav_menu_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "links"]

  toggle(event) {
    event.stopPropagation()
    if (this.linksTarget.hasAttribute("data-open")) return this.close()

    this.linksTarget.setAttribute("data-open", "")
    this.toggleTarget.setAttribute("aria-expanded", "true")
  }

  closeOnOutsideClick(event) {
    if (!this.open) return
    if (this.linksTarget.contains(event.target)) return
    this.close()
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return
    if (!this.open) return

    this.close()
    this.toggleTarget.focus()
  }

  close() {
    this.linksTarget.removeAttribute("data-open")
    this.toggleTarget.setAttribute("aria-expanded", "false")
  }

  get open() {
    return this.linksTarget.hasAttribute("data-open")
  }
}
