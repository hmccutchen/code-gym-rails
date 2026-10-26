// Design notes: docs/code-notes/app/javascript/controllers/concept_alternates_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

// Module-level and keyed by reference id so every copy of one reference on the page shares the max cap.
const framings = new Map()

export default class extends Controller {
  static targets = ["button", "status"]

  static values = {
    url: String,
    referenceId: String,
    max: Number,
    thinkingText: String,
    addedText: String,
    addedLastText: String,
    failedText: String
  }

  async explain() {
    const buttons = this.peerButtons
    buttons.forEach((button) => (button.disabled = true))
    this.statusTarget.textContent = this.thinkingTextValue

    const result = await request.send("POST", this.urlValue,
      { prior_alternates: this.priorFramings }, { fallback: this.failedTextValue })
    const data = result.data

    if (result.ok && data?.status === "ok" && data.alternate) {
      this.addFraming(data.alternate, data.alternate_html, data.remaining, buttons)
    } else {
      this.statusTarget.textContent = result.message || this.failedTextValue
      if (this.priorFramings.length < this.maxValue) buttons.forEach((button) => (button.disabled = false))
    }
  }

  addFraming(alternate, alternateHtml, remaining, buttons) {
    framings.set(this.referenceIdValue, [ ...this.priorFramings, alternate ])

    let focused = null
    this.peerContainers.forEach((container) => {
      const paragraph = document.createElement("p")
      paragraph.className = "alternate-item"
      if (typeof alternateHtml === "string") {
        paragraph.innerHTML = alternateHtml
      } else {
        paragraph.textContent = alternate
      }
      paragraph.tabIndex = -1
      container.insertBefore(paragraph, container.querySelector(".explain-concept-differently"))
      if (container === this.element) focused = paragraph
    })

    // Set, never cleared: the framing lands outside this live region, so clearing it announces nothing.
    this.statusTarget.textContent = remaining > 0 ? this.addedTextValue : this.addedLastTextValue

    if (remaining > 0) {
      buttons.forEach((button) => (button.disabled = false))
      return
    }

    // Before the removal: removing the focused button drops focus to the body.
    if (focused) focused.focus()
    buttons.forEach((button) => button.remove())
  }

  get priorFramings() {
    return framings.get(this.referenceIdValue) || []
  }

  get peerContainers() {
    return [ ...document.querySelectorAll(`.concept-alternates[data-concept-alternates-reference-id-value="${this.referenceIdValue}"]`) ]
  }

  get peerButtons() {
    return this.peerContainers
      .map((container) => container.querySelector(".explain-concept-differently"))
      .filter(Boolean)
  }
}
