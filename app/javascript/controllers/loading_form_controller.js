// Design notes: docs/code-notes/app/javascript/controllers/loading_form_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { label: String, confirmMessage: String }

  connect() {
    this.button = this.element.querySelector('button[type="submit"], input[type="submit"]')
    if (!this.button) return

    this.isButtonTag = this.button.tagName === "BUTTON"
    this.originalLabel = this.isButtonTag ? this.button.textContent : this.button.value
    // A form that must not submit before this connects renders its button disabled (see the design notes).
    this.button.disabled = false
  }

  submit(event) {
    if (!this.button) return
    if (this.confirmMessageValue && !window.confirm(this.confirmMessageValue)) return event.preventDefault()

    // Deferred a tick: disabling synchronously inside the submit handler can cancel the submission.
    setTimeout(() => {
      this.button.disabled = true
      this.button.classList.add("btn-loading")
      if (this.labelValue) this.setLabel(this.labelValue)
    }, 0)
  }

  restore(event) {
    if (!this.button || !event.persisted) return

    this.button.disabled = false
    this.button.classList.remove("btn-loading")
    this.setLabel(this.originalLabel)
  }

  setLabel(text) {
    if (this.isButtonTag) { this.button.textContent = text } else { this.button.value = text }
  }
}
