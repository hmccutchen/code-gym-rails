// Design notes: docs/code-notes/app/javascript/controllers/fresh_day_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static values = {
    url: String,
    shown: String,
    minimumGap: Number,
    replacedText: String
  }

  connect() {
    this.stopped = false
    this.checking = false
    this.checkedAt = Date.now()
  }

  disconnect() {
    this.stopped = true
  }

  present() {
    if (this.stopped || this.checking || document.visibilityState !== "visible") return
    if (Date.now() - this.checkedAt < this.minimumGapValue) return

    this.check()
  }

  async check() {
    this.checking = true
    this.checkedAt = Date.now()

    const { data } = await request.get(`${this.urlValue}?${new URLSearchParams({ shown: this.shownValue })}`)
    this.checking = false
    if (this.stopped || data?.stale !== true) return

    this.stopped = true
    saveStatus.leaveWhenSaved(() => this.reload(data.replaced === true), () => {})
  }

  reload(replaced) {
    if (replaced) saveStatus.carry("answers", this.replacedTextValue)
    window.location.reload()
  }
}
