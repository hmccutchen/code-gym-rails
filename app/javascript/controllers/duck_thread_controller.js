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
    assistantSpeaker: String,
    turns: Array,
    version: Number
  }

  connect() {
    this.thread = this.turnsValue.map((turn) => ({ role: turn.role, content: turn.content }))
    this.version = this.versionValue
    this.generation = 0
    this.clearing = Promise.resolve()
    if (this.thread.length > 0) {
      this.renderTurns()
      this.refreshCap()
    }
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
    const cleared = this.thread
    this.generation += 1
    this.thread = []
    // input.value is left alone: after a failed send it holds text to retry, and Clear names the conversation.
    this.statusTarget.textContent = ""
    this.renderTurns()
    this.refreshCap()
    this.clearing = this.clearStored(cleared)
  }

  async clearStored(cleared) {
    const result = await request.send("DELETE", this.urlValue, { section: this.sectionValue },
      { fallback: this.sendFailedTextValue })
    if (result.ok && typeof result.data?.version === "number") {
      this.version = result.data.version
      return
    }
    this.thread = cleared
    this.renderTurns()
    this.refreshCap()
    this.statusTarget.textContent = result.message || this.sendFailedTextValue
  }

  async ask(explicitMessage) {
    const message = explicitMessage || this.inputTarget.value.trim()
    if (!message || this.sendTarget.disabled) return

    const generation = this.generation
    this.disableControls(true)
    this.statusTarget.textContent = this.thinkingTextValue

    await this.clearing
    const result = await request.send("POST", this.urlValue,
      { section: this.sectionValue, message: message, version: this.version },
      { fallback: this.sendFailedTextValue })
    // Clear ran while this was in flight; dropping the reply keeps a cleared thread cleared.
    if (generation !== this.generation) return

    if (result.ok && result.data) {
      this.version = result.data.version
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
