// Design notes: docs/code-notes/app/javascript/controllers/duck_thread_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["body", "toggle", "turns", "input", "send", "explain", "status"]

  static values = {
    section: String,
    url: String,
    maxTurns: Number,
    explainMessage: String,
    sendFailedText: String,
    thinkingText: String,
    cappedText: String,
    userSpeaker: String,
    assistantSpeaker: String
  }

  connect() {
    this.thread = []
    this.generation = 0
  }

  toggle() {
    this.bodyTarget.hidden = !this.bodyTarget.hidden
    this.toggleTarget.setAttribute("aria-expanded", String(!this.bodyTarget.hidden))
  }

  send() {
    this.ask()
  }

  explain() {
    this.ask(this.explainMessageValue)
  }

  clear() {
    this.generation += 1
    this.thread = []
    // input.value is left alone: after a failed send it holds text to retry, and Clear names the conversation.
    this.statusTarget.textContent = ""
    this.renderTurns()
    this.refreshCap()
  }

  async ask(explicitMessage) {
    const message = explicitMessage || this.inputTarget.value.trim()
    if (!message || this.sendTarget.disabled) return

    const priorThread = this.thread.slice()
    const generation = this.generation
    this.disableControls(true)
    this.statusTarget.textContent = this.thinkingTextValue

    const result = await request.send("POST", this.urlValue,
      { section: this.sectionValue, message: message, thread: priorThread },
      { fallback: this.sendFailedTextValue })
    // Clear ran while this was in flight; dropping the reply keeps a cleared thread cleared.
    if (generation !== this.generation) return

    if (result.ok && result.data) {
      this.thread.push({ role: "user", content: message }, { role: "assistant", content: result.data.answer })
      this.renderTurns()
      if (!explicitMessage) this.inputTarget.value = ""
      this.statusTarget.textContent = ""
    } else {
      this.statusTarget.textContent = result.message || this.sendFailedTextValue
    }
    this.refreshCap()
  }

  renderTurns() {
    this.turnsTarget.replaceChildren()
    this.thread.forEach((turn) => {
      const paragraph = document.createElement("p")
      paragraph.className = `duck-turn duck-${turn.role}`
      paragraph.appendChild(this.speakerLabel(turn.role))
      paragraph.appendChild(document.createTextNode(turn.content))
      this.turnsTarget.appendChild(paragraph)
    })
  }

  // Without this the speaker shows only as CSS colour, which assistive tech never receives.
  speakerLabel(role) {
    const label = document.createElement("span")
    label.className = "visually-hidden"
    const speaker = role === "user" ? this.userSpeakerValue : this.assistantSpeakerValue
    label.textContent = `${speaker}: `
    return label
  }

  // Writes the status only when capped: clearing it here would wipe every error message ask just set.
  refreshCap() {
    const used = this.thread.filter((turn) => turn.role === "user").length
    const capped = used >= this.maxTurnsValue
    this.disableControls(capped)
    if (capped) this.statusTarget.textContent = this.cappedTextValue
  }

  disableControls(disabled) {
    this.inputTarget.disabled = disabled
    this.sendTarget.disabled = disabled
    this.explainTarget.disabled = disabled
  }
}
