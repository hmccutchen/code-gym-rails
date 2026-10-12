// Design notes: docs/code-notes/app/javascript/controllers/review_alternates_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["button", "status"]

  static values = {
    section: String,
    url: String,
    thinkingText: String,
    addedText: String,
    addedLastText: String,
    failedText: String
  }

  async explain() {
    this.buttonTarget.disabled = true
    this.statusTarget.textContent = this.thinkingTextValue

    const result = await request.send("POST", this.urlValue,
      { section: this.sectionValue }, { fallback: this.failedTextValue })
    const data = result.data

    if (result.ok && data) {
      const paragraph = document.createElement("p")
      paragraph.className = "alternate-item"
      paragraph.textContent = data.alternate
      this.element.insertBefore(paragraph, this.buttonTarget)
      // Set, never cleared: the explanation lands outside this live region.
      this.statusTarget.textContent = data.remaining > 0 ? this.addedTextValue : this.addedLastTextValue
      if (data.remaining > 0) this.buttonTarget.disabled = false
      else this.buttonTarget.remove()
    } else {
      this.statusTarget.textContent = result.message || this.failedTextValue
      this.buttonTarget.disabled = false
    }
  }
}
