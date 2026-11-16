// Design notes: docs/code-notes/app/javascript/controllers/fresh_day_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

const REPLACED_NOTICE = "replaced"

export default class extends Controller {
  static values = {
    url: String,
    shown: String,
    minimumGap: Number,
    noticeShownFor: Number,
    replacedText: String
  }

  connect() {
    this.stopped = false
    this.checking = false
    this.checkedAt = Date.now()
    this.connectedAt = Date.now()
    this.noticeDismissed = false
  }

  disconnect() {
    this.stopped = true
  }

  present() {
    if (this.stopped || document.visibilityState !== "visible") return
    this.dismissNotice()
    if (this.checking) return
    if (Date.now() - this.checkedAt < this.minimumGapValue) return

    this.check()
  }

  dismissNotice() {
    if (this.noticeDismissed || Date.now() - this.connectedAt < this.noticeShownForValue) return

    this.noticeDismissed = true
    saveStatus.clear(REPLACED_NOTICE)
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
    if (replaced) saveStatus.carry(REPLACED_NOTICE, this.replacedTextValue)
    window.location.reload()
  }
}
