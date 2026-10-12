// Design notes: docs/code-notes/app/javascript/controllers/review_button_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]

  static values = { loadingLabel: String }

  connect() {
    this.originalLabel = this.buttonTarget.textContent
    this.onPageShow = (event) => { if (event.persisted) this.restore() }
    window.addEventListener("pageshow", this.onPageShow)
  }

  disconnect() {
    window.removeEventListener("pageshow", this.onPageShow)
  }

  submit() {
    // Disabling synchronously inside the submit handler can cancel the submission in some browsers.
    setTimeout(() => {
      this.buttonTarget.disabled = true
      this.buttonTarget.classList.add("btn-loading")
      this.buttonTarget.textContent = this.loadingLabelValue
    }, 0)
  }

  restore() {
    this.buttonTarget.disabled = false
    this.buttonTarget.classList.remove("btn-loading")
    this.buttonTarget.textContent = this.originalLabel
  }
}
