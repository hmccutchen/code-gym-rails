import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["question", "section", "input", "save", "status"]

  static values = { url: String, failedText: String }

  choose() {
    this.questionTarget.textContent = this.sectionTarget.selectedOptions[0].dataset.question
  }

  async save() {
    this.saveTarget.disabled = true
    this.statusTarget.textContent = ""
    const result = await request.send("POST", this.urlValue,
      { section: this.sectionTarget.value, explanation: this.inputTarget.value }, { fallback: this.failedTextValue })
    // The server renders the box's next state, saved or closed, so the page holds no rule for it.
    if (result.data?.html) {
      this.element.outerHTML = result.data.html
      return
    }
    this.saveTarget.disabled = false
    this.statusTarget.textContent = result.message || this.failedTextValue
  }
}
