// Design notes: docs/code-notes/app/javascript/controllers/fresh_day_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

const REPLACED_NOTICE = "replaced"
const BANNER_REFRESH_MS = 250

export default class extends Controller {
  static targets = ["banner", "sentence", "unsaved", "reload"]

  static values = {
    url: String,
    shown: String,
    minimumGap: Number,
    noticeShownFor: Number,
    replacedText: String,
    banner: Boolean,
    unsavedText: String,
    reloadLabel: String,
    discardLabel: String
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
    clearInterval(this.bannerRefresh)
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
    if (this.stopped) return
    if (this.bannerValue && this.answeredWithBanner(data)) return
    if (data?.stale !== true) return

    this.stopped = true
    saveStatus.leaveWhenSaved(() => this.reload(data.replaced === true), () => {})
  }

  answeredWithBanner(data) {
    const outOfDate = data?.out_of_date === true
    if (!outOfDate && !(data?.stale === true && saveStatus.unsaved())) return false

    this.showBanner(data.banner)
    return true
  }

  notCurrent(event) {
    if (this.bannerValue && this.hasBannerTarget) this.showBanner(event.detail?.banner)
  }

  staleSave(event) {
    if (!this.bannerValue || !this.hasBannerTarget) return
    if (this.bannerTarget.hidden && !saveStatus.unsaved(...(event.detail?.ignored ?? []))) return

    event.preventDefault()
    this.showBanner(event.detail?.banner)
  }

  showBanner(sentence) {
    this.stopped = true
    window.dispatchEvent(new CustomEvent("code-gym:stale-practice"))
    if (this.bannerTarget.hidden) {
      this.unsavedTarget.textContent = this.unsavedTextValue
      this.refreshBanner()
      this.bannerTarget.hidden = false
      this.bannerRefresh = setInterval(() => this.refreshBanner(), BANNER_REFRESH_MS)
    }
    if (typeof sentence === "string" && sentence !== "") this.sentenceTarget.textContent = sentence
  }

  refreshBanner() {
    const unsaved = saveStatus.unsaved()
    this.unsavedTarget.hidden = !unsaved
    this.reloadTarget.textContent = unsaved ? this.discardLabelValue : this.reloadLabelValue
  }

  reloadNow() {
    const discarding = saveStatus.unsaved()
    this.reloadTarget.disabled = true
    clearInterval(this.bannerRefresh)
    saveStatus.leaveDiscarding(() => {
      if (discarding) window.dispatchEvent(new CustomEvent("code-gym:discard-draft"))
      window.location.reload()
    })
  }

  reload(replaced) {
    if (replaced) saveStatus.carry(REPLACED_NOTICE, this.replacedTextValue)
    window.location.reload()
  }
}
