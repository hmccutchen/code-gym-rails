// Design notes: docs/code-notes/app/javascript/controllers/answer_form_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"
import draftStore from "code_gym/draft_store"

const AUTOSAVE_DELAY_MS = 800

export default class extends Controller {
  static targets = ["form", "progressFill", "progressLabel", "submitButton", "nudge"]

  static values = {
    answeredSections: Array,
    submitBlocker: String,
    draftScope: String,
    draftToken: String,
    answeredCount: String,
    allAnswered: String,
    staleReloaded: String,
    submitting: String,
    submitLabel: String,
    generatingReview: String,
    submitFailed: String,
    savingOffline: String,
    submitOffline: String,
    reviewStartFailed: String,
    controlsNotReady: String
  }

  connect() {
    this.textareas = [...this.formTarget.querySelectorAll("textarea[data-field]")]
    this.sectionFields = this.textareas.map((area) => area.dataset.field)
    this.answered = new Set(this.answeredSectionsValue)
    this.blocker = this.submitBlockerValue || null
    this.saveTimer = null
    this.reviewRequested = false

    this.ratings = {}
    this.formTarget.querySelectorAll("button.rating-btn.active").forEach((button) => {
      this.ratings[button.dataset.ratingFor] = button.dataset.rating
    })

    this.draftToken = this.draftTokenValue
    this.offlineSubmit = false
    const restored = this.restoreDraft()

    saveStatus.watch(() => this.saveTimer !== null)
    if (restored || this.textareas.some((area) => area.value !== area.defaultValue)) this.autoSave()
    this.onOnline = () => this.retryAfterOfflineSubmit()
    window.addEventListener("online", this.onOnline)
    this.onPageShow = (event) => {
      // Safari bfcaches this no-store page anyway (every iOS home-screen launch), so reload a stale submitted form.
      if (event.persisted && this.reviewRequested) window.location.reload()
    }
    window.addEventListener("pageshow", this.onPageShow)

    this.updateProgress()
  }

  disconnect() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    window.removeEventListener("pageshow", this.onPageShow)
    window.removeEventListener("online", this.onOnline)
  }

  restoreDraft() {
    const draft = draftStore.read()
    if (!draft || draft.token !== this.draftToken) {
      draftStore.clear()
      return false
    }
    this.textareas.filter((area) => !area.closest("[data-controller~='parsons']")).forEach((area) => {
      const saved = draft.answers?.[area.dataset.field]
      if (typeof saved !== "string" || area.value !== area.defaultValue) return
      area.value = saved
      area.dispatchEvent(new CustomEvent("answer-form:restored", { bubbles: true }))
    })
    Object.entries(draft.ratings || {}).forEach(([section, rating]) => this.showRating(section, rating))
    return true
  }

  storeDraft() {
    if (this.formTarget.inert) return
    const { answers, section_ratings } = this.payload().response
    draftStore.write({ token: this.draftToken, answers: answers, ratings: section_ratings })
  }

  settleDraft(data) {
    if (typeof data?.draft_token === "string") this.draftToken = data.draft_token
    if (JSON.stringify(this.lastSent) === JSON.stringify(this.payload())) draftStore.clear()
    else this.storeDraft()
  }

  nextSave() {
    if (this.formTarget.inert) return null
    this.lastSent = this.payload()
    return this.lastSent
  }

  isAnswered(textarea) {
    return this.answered.has(textarea.dataset.field)
  }

  applyServerState(data) {
    if (!Array.isArray(data?.answered_sections)) return
    this.answered = new Set(data.answered_sections)
    this.blocker = data.submit_blocker || null
    this.updateProgress()
    this.refreshNudge()
    Object.entries(data.section_statuses || {}).forEach(([section, text]) => {
      const status = this.formTarget.querySelector(`.section-status[data-status-for="${section}"]`)
      if (status) status.textContent = text
    })
  }

  refreshNudge() {
    this.nudgeTarget.hidden = this.blocker === null
    if (this.blocker) this.nudgeTarget.textContent = this.nudgeTarget.dataset[this.blocker]
  }

  updateProgress() {
    const total = this.sectionFields.length
    const filled = this.textareas.filter((area) => this.isAnswered(area)).length
    this.progressFillTarget.style.width = (filled / total * 100) + "%"
    this.progressLabelTarget.textContent = filled === total
      ? this.allAnsweredValue
      : this.answeredCountValue.replace("%{answered}", filled).replace("%{total}", total)
    this.formTarget.querySelectorAll(".hint-slot[data-hint-for]").forEach((slot) => {
      const area = this.formTarget.querySelector(`textarea[data-field="${slot.dataset.hintFor}"]`)
      if (area) this.setHintLocked(slot, !this.isAnswered(area))
    })
  }

  setHintLocked(slot, locked) {
    slot.querySelector(".hint-locked").hidden = !locked
    const disclosure = slot.querySelector(":scope > details.hint")
    if (locked) disclosure?.remove()
    else if (!disclosure) slot.querySelector(".hint-locked").after(slot.querySelector("template").content.cloneNode(true))
  }

  payload(extra) {
    const answers = {}
    this.textareas.forEach((area) => answers[area.dataset.field] = area.value)
    return { response: Object.assign({ answers: answers, section_ratings: this.ratings, draft_scope: this.draftScopeValue }, extra || {}) }
  }

  sendSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    if (this.formTarget.inert) return
    this.storeDraft()
    saveStatus.queue("answers", "POST", this.formTarget.action, () => this.nextSave(), { latest: true, offline: this.savingOfflineValue })
      .then(({ ok, status, data, skipped }) => {
        if (skipped) return
        if (ok) saveStatus.clear("submit")
        if (ok) this.settleDraft(data)
        if (!ok && status === 409 && data?.status === "stale") {
          draftStore.clear()
          saveStatus.carry("answers", this.staleReloadedValue)
          window.location.reload()
          return
        }
        if (ok && data?.submitted && !this.formTarget.inert && !this.reviewRequested) {
          draftStore.clear()
          return window.location.reload()
        }
        if (ok && this.saveTimer === null && !saveStatus.queued("answers") && !this.formTarget.inert) this.applyServerState(data)
      })
  }

  autoSave() {
    clearTimeout(this.saveTimer)
    this.storeDraft()
    this.saveTimer = this.formTarget.inert ? null : setTimeout(() => this.sendSave(), AUTOSAVE_DELAY_MS)
  }

  change(event) {
    if (event.target.closest("[data-field], [data-comparison-answer]")) this.sendSave()
  }

  input(event) {
    const field = event.target.closest("textarea[data-field]")
    if (!field) return
    this.reopenIfRated(field.dataset.field)
    this.autoSave()
  }

  reopenIfRated(section) {
    const fold = this.formTarget.querySelector(`details.section[data-section-fold="${section}"]`)
    if (fold && !fold.open && this.ratings[section]) fold.open = true
  }

  rate(event) {
    const button = event.target.closest("button[data-rating-for]")
    if (!button) return
    this.showRating(button.dataset.ratingFor, button.dataset.rating)
    this.sendSave()
  }

  showRating(section, rating) {
    const buttons = [...this.formTarget.querySelectorAll(`button[data-rating-for="${section}"]`)]
    const chosen = buttons.find((button) => button.dataset.rating === rating)
    if (!chosen) return
    this.ratings[section] = rating
    buttons.forEach((other) => {
      other.classList.toggle("active", other === chosen)
      other.setAttribute("aria-pressed", other === chosen)
    })
  }

  requestReview(url) {
    const reviewForm = document.createElement("form")
    reviewForm.method = "post"
    reviewForm.action = url
    const token = document.createElement("input")
    token.type = "hidden"
    token.name = "authenticity_token"
    token.value = document.querySelector('meta[name="csrf-token"]')?.content ?? ""
    reviewForm.appendChild(token)
    document.body.appendChild(reviewForm)
    reviewForm.submit()
  }

  async submit(event) {
    event.preventDefault()
    if (this.formTarget.inert) return
    this.lockForSubmit()

    // A kind whose answer only reaches the hidden field through its own controller would otherwise submit the stale one.
    await window.CodeGymBootstrap?.ready
    if (!this.formControllersConnected()) {
      saveStatus.report("submit", this.controlsNotReadyValue)
      return this.unlock()
    }

    const result = await request.send("POST", this.formTarget.action, this.payload({ submit: "1" }), { fallback: this.submitFailedValue })
    if (result.ok) saveStatus.clear("submit")
    if (result.ok) draftStore.clear()
    if (this.startReview(result) || this.reloadAfterSubmit(result)) return

    const refused = result.status === 422 && Boolean(result.data?.submit_blocker)
    if (refused) {
      saveStatus.clear("submit")
      this.applyServerState(result.data)
    } else {
      this.offlineSubmit = result.status === 0
      saveStatus.report("submit", this.offlineSubmit ? this.submitOfflineValue : result.message)
    }
    this.unlock({ autosave: !this.offlineSubmit })
    if (refused) this.nudgeTarget.focus()
  }

  retryAfterOfflineSubmit() {
    if (!this.offlineSubmit) return
    this.offlineSubmit = false
    saveStatus.clear("submit")
    this.autoSave()
  }

  formControllersConnected() {
    return [...this.formTarget.querySelectorAll("[data-controller]")].every((element) =>
      element.dataset.controller.split(/\s+/).filter(Boolean).every((identifier) =>
        this.application.getControllerForElementAndIdentifier(element, identifier)))
  }

  lockForSubmit() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    this.formTarget.inert = true
    this.submitButtonTarget.disabled = true
    this.submitButtonTarget.classList.add("btn-loading")
    this.submitButtonTarget.textContent = this.submittingValue
  }

  startReview(result) {
    const reviewUrl = result.ok ? result.data?.review_url : null
    if (!reviewUrl) return false
    this.submitButtonTarget.textContent = this.generatingReviewValue
    this.reviewRequested = true
    try {
      this.requestReview(reviewUrl)
      return true
    } catch (_) {
      this.reviewRequested = false
      return false
    }
  }

  // Stays inert behind the reload: restoring the form would queue an autosave of the refused payload.
  reloadAfterSubmit(result) {
    const stale = result.status === 409
    if (!result.ok && !stale) return false
    draftStore.clear()
    saveStatus.carry("answers", result.ok ? this.reviewStartFailedValue : this.staleReloadedValue)
    window.location.reload()
    return true
  }

  unlock({ autosave = true } = {}) {
    this.formTarget.inert = false
    this.submitButtonTarget.classList.remove("btn-loading")
    this.submitButtonTarget.textContent = this.submitLabelValue
    this.submitButtonTarget.disabled = false
    if (autosave) this.autoSave()
  }
}
