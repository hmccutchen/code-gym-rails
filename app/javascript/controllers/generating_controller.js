// Design notes: docs/code-notes/app/javascript/controllers/generating_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["hint"]

  static values = {
    url: String,
    interval: Number,
    maxAttempts: Number,
    slowHint: String
  }

  connect() {
    this.attempts = 0
    this.stopped = false
    this.schedule()
  }

  disconnect() {
    this.stopped = true
    clearTimeout(this.timer)
  }

  schedule() {
    this.timer = setTimeout(() => this.poll(), this.intervalValue)
  }

  async poll() {
    this.attempts += 1

    const { data } = await request.get(this.urlValue)
    if (this.stopped) return

    if (data?.status === "ready" || data?.status === "failed") {
      saveStatus.leaveWhenSaved(() => window.location.reload(), () => this.schedule())
      return
    }

    if (this.attempts >= this.maxAttemptsValue) {
      this.hintTarget.textContent = this.slowHintValue
      return
    }

    this.schedule()
  }
}
