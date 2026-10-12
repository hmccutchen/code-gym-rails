// Design notes: docs/code-notes/app/javascript/controllers/follow_ups_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["form", "input", "send", "thread", "status"]

  static values = {
    section: String,
    url: String,
    thinkingText: String,
    cappedText: String,
    failedText: String
  }

  enter(event) {
    if (event.key !== "Enter") return
    event.preventDefault()
    this.send()
  }

  async send() {
    const question = this.inputTarget.value.trim()
    if (!question) return
    this.disableControls(true)
    this.statusTarget.textContent = this.thinkingTextValue

    const result = await request.send("POST", this.urlValue,
      { section: this.sectionValue, question: question }, { fallback: this.failedTextValue })
    const data = result.data

    if (result.ok && data) {
      this.addTurn("user", data.question)
      this.addTurn("assistant", data.answer)
      this.inputTarget.value = ""
      this.statusTarget.textContent = ""
      if (data.remaining > 0) this.disableControls(false)
      else this.capForm()
    } else {
      this.statusTarget.textContent = result.message || this.failedTextValue
      this.disableControls(false)
    }
  }

  addTurn(role, text) {
    const paragraph = document.createElement("p")
    paragraph.className = `follow-up-turn follow-up-${role}`
    paragraph.textContent = text
    this.threadTarget.appendChild(paragraph)
  }

  capForm() {
    this.formTarget.remove()
    const capped = document.createElement("p")
    capped.className = "follow-up-capped"
    capped.textContent = this.cappedTextValue
    this.element.insertBefore(capped, this.statusTarget)
  }

  disableControls(disabled) {
    this.inputTarget.disabled = disabled
    this.sendTarget.disabled = disabled
  }
}
