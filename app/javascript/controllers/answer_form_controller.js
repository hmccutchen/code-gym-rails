// Design notes: docs/code-notes/app/javascript/controllers/answer_form_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

const AUTOSAVE_DELAY_MS = 800

export default class extends Controller {
  static targets = ["form", "progressFill", "progressLabel", "submitButton", "nudge"]

  static values = {
    answeredSections: Array,
    submitBlocker: String,
    answeredCount: String,
    allAnswered: String,
    staleReloaded: String,
    submitting: String,
    submitLabel: String,
    generatingReview: String,
    submitFailed: String,
    reviewStartFailed: String
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

    saveStatus.watch(() => this.saveTimer !== null)
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
    return { response: Object.assign({ answers: answers, section_ratings: this.ratings }, extra || {}) }
  }

  sendSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    if (this.formTarget.inert) return
    saveStatus.queue("answers", "POST", this.formTarget.action, () => (this.formTarget.inert ? null : this.payload()), { latest: true })
      .then(({ ok, status, data, skipped }) => {
        if (skipped) return
        if (ok) saveStatus.clear("submit")
        if (!ok && status === 409 && data?.status === "stale") {
          saveStatus.carry("answers", this.staleReloadedValue)
          window.location.reload()
          return
        }
        if (ok && data?.submitted && !this.formTarget.inert && !this.reviewRequested) return window.location.reload()
        if (ok && this.saveTimer === null && !saveStatus.queued("answers") && !this.formTarget.inert) this.applyServerState(data)
      })
  }

  autoSave() {
    clearTimeout(this.saveTimer)
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
    const section = button.dataset.ratingFor
    this.ratings[section] = button.dataset.rating
    this.formTarget.querySelectorAll(`button[data-rating-for="${section}"]`).forEach((other) => {
      other.classList.toggle("active", other === button)
      other.setAttribute("aria-pressed", other === button)
    })
    this.sendSave()
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
    clearTimeout(this.saveTimer)
    this.saveTimer = null

    this.formTarget.inert = true
    this.submitButtonTarget.disabled = true
    this.submitButtonTarget.classList.add("btn-loading")
    this.submitButtonTarget.textContent = this.submittingValue

    const result = await request.send("POST", this.formTarget.action, this.payload({ submit: "1" }), { fallback: this.submitFailedValue })
    const reviewUrl = result.ok ? result.data?.review_url : null
    if (result.ok) saveStatus.clear("submit")

    if (reviewUrl) {
      this.submitButtonTarget.textContent = this.generatingReviewValue
      this.reviewRequested = true
      try { this.requestReview(reviewUrl); return } catch (_) { this.reviewRequested = false }
    }
    // Stays inert behind the reload: restoring the form would queue an autosave of the refused payload.
    if (result.ok || result.status === 409) {
      saveStatus.carry("answers", result.ok ? this.reviewStartFailedValue : this.staleReloadedValue)
      window.location.reload()
      return
    }

    const refused = result.status === 422 && Boolean(result.data?.submit_blocker)
    if (refused) {
      saveStatus.clear("submit")
      this.applyServerState(result.data)
    } else {
      saveStatus.report("submit", result.message)
    }

    this.formTarget.inert = false
    this.submitButtonTarget.classList.remove("btn-loading")
    this.submitButtonTarget.textContent = this.submitLabelValue
    this.submitButtonTarget.disabled = false
    this.autoSave()
    if (refused) this.nudgeTarget.focus()
  }
}
