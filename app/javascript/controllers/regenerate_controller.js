import { Controller } from "@hotwired/stimulus"

// Attached to the "Generate new set" button_to form. regenerate stays a
// fully synchronous POST (see docs/superpowers/specs/2026-07-12-visual-feedback-design.md),
// so this only gives the ~10s wait a disabled/spinner button state instead
// of silence.
export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.originalLabel = this.buttonTarget.textContent
  }

  start() {
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Generating…"
  }

  stop() {
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = this.originalLabel
  }
}
