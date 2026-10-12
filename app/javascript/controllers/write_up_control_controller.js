// Design notes: docs/code-notes/app/javascript/controllers/write_up_control_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["button", "status"]

  static values = {
    url: String,
    statusUrl: String,
    rewrittenUrl: String,
    intervalMs: Number,
    maxAttempts: Number,
    writingText: String,
    failedText: String
  }

  connect() {
    this.attempts = 0
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  async start() {
    this.attempts = 0
    this.buttonTarget.disabled = true
    this.statusTarget.textContent = this.writingTextValue

    const result = await request.send("POST", this.urlValue, undefined, { fallback: this.failedTextValue })
    if (result.ok) return this.poll()

    this.buttonTarget.disabled = false
    this.statusTarget.textContent = result.message
  }

  async poll() {
    this.attempts++
    if (this.attempts > this.maxAttemptsValue) {
      this.statusTarget.textContent = this.failedTextValue
      return
    }

    const { ok, data } = await request.get(this.statusUrlValue)
    if (!ok || !data) return this.pollLater()
    if (data.ready) return window.location.reload()
    if (data.rewritten) return window.location.assign(this.rewrittenUrlValue)
    if (data.failed) {
      this.statusTarget.textContent = data.message
      this.buttonTarget.disabled = false
      return
    }
    this.pollLater()
  }

  pollLater() {
    this.timer = setTimeout(() => this.poll(), this.intervalMsValue)
  }
}
