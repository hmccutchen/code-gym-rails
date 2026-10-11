// Design notes: docs/code-notes/app/javascript/controllers/pseudocode_round_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["button", "status", "output"]

  static values = {
    section: String,
    url: String,
    headingText: String,
    noGapsText: String,
    workingText: String,
    failedText: String
  }

  // One-shot round: stays locked on success, re-enables on failure since the cap wasn't consumed.
  async critique() {
    if (this.buttonTarget.disabled) return
    this.buttonTarget.disabled = true
    this.statusTarget.textContent = this.workingTextValue

    const result = await request.send("POST", this.urlValue,
      { section: this.sectionValue, pseudocode: this.answerField()?.value },
      { fallback: this.failedTextValue })
    const data = result.data

    if (result.ok && data && (!data.gaps_found || Array.isArray(data.gaps))) {
      this.renderCritique(data)
      this.statusTarget.textContent = ""
    } else {
      this.statusTarget.textContent = result.message || this.failedTextValue
      this.buttonTarget.disabled = false
    }
  }

  renderCritique(data) {
    this.outputTarget.replaceChildren()
    const label = document.createElement("p")
    label.className = "pseudocode-critique-label"
    if (!data.gaps_found) {
      label.textContent = this.noGapsTextValue
      this.outputTarget.appendChild(label)
      return
    }
    label.textContent = this.headingTextValue
    const list = document.createElement("ul")
    data.gaps.forEach((gap) => {
      const item = document.createElement("li")
      // textContent, never innerHTML: this is provider output.
      item.textContent = gap
      list.appendChild(item)
    })
    this.outputTarget.append(label, list)
  }

  answerField() {
    return document.querySelector(`textarea[data-field="${this.sectionValue}"]`)
  }
}
