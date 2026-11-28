// Design notes: docs/code-notes/app/javascript/controllers/answer_form_controller.md
import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"
import DraftCopy from "code_gym/draft_store"

const AUTOSAVE_DELAY_MS = 800

export default class extends Controller {
  static targets = ["form", "sections", "submitButton", "nudge", "replaceButton"]

  static values = {
    answeredSections: Array,
    submitBlocker: String,
    draftScope: String,
    manifestRevision: Number,
    additionPending: Boolean,
    emptyUnratedSections: Array,
    draftToken: String,
    staleReloaded: String,
    submitting: String,
    submitLabel: String,
    generatingReview: String,
    submitFailed: String,
    savingOffline: String,
    submitOffline: String,
    reviewStartFailed: String,
    controlsNotReady: String,
    leaveHeld: String,
    reloadNow: String
  }

  connect() {
    this.textareas = [...this.formTarget.querySelectorAll("textarea[data-field]")]
    this.answered = new Set(this.answeredSectionsValue)
    this.blocker = this.submitBlockerValue || null
    this.saveTimer = null
    this.reviewRequested = false
    this.answersConfirmed = true
    this.heldEdits = false
    this.additionPending = this.additionPendingValue

    this.ratings = {}
    this.formTarget.querySelectorAll("button.rating-btn.active").forEach((button) => {
      this.ratings[button.dataset.ratingFor] = button.dataset.rating
    })

    if (this.draft) this.draft.reconnect(this.draftTokenValue, this.draftScopeValue)
    else this.draft = new DraftCopy(this.draftTokenValue, this.draftScopeValue)
    this.offlineSubmit = false
    const restored = this.restoreDraft()

    saveStatus.watch(() => this.saveTimer !== null)
    saveStatus.watchUnsent(() => this.element.isConnected && this.heldEdits)
    if (restored || this.textareas.some((area) => area.value !== area.defaultValue)) this.autoSave()

    this.updateHints()
    this.updateSubmit()
    window.CodeGymBootstrap?.ready?.then(() => this.refreshConnectedControls())
  }

  refreshConnectedControls() {
    if (!this.element.isConnected) return
    if (!this.formControllersConnected()) saveStatus.report("submit", this.controlsNotReadyValue)
    this.updateSubmit()
  }

  disconnect() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
  }

  // Safari bfcaches this no-store page anyway (every iOS home-screen launch), so reload a stale submitted form.
  pageShow(event) {
    if (event.persisted && this.reviewRequested) window.location.reload()
  }

  restoreDraft() {
    const draft = this.draft.restorable(this.rendered())
    if (!draft) return false
    let keptEarlyEdit = false
    this.textareas.filter((area) => area.dataset.draftRestore !== "off").forEach((area) => {
      const saved = draft.answers?.[area.dataset.field]
      if (typeof saved !== "string") return
      if (area.value !== area.defaultValue) {
        if (area.value !== saved) keptEarlyEdit = true
        return
      }
      area.value = saved
      area.dispatchEvent(new CustomEvent("answer-form:restored", { bubbles: true }))
    })
    Object.entries(draft.ratings || {}).forEach(([section, rating]) => this.showRating(section, rating))
    if (!keptEarlyEdit) this.draft.takeOverUnconfirmedSaves()
    return true
  }

  rendered() {
    const answers = {}
    this.textareas.forEach((area) => answers[area.dataset.field] = area.defaultValue)
    return { answers: answers, ratings: this.ratings, emptyUnratedSections: this.emptyUnratedSectionsValue }
  }

  onScreen(save = this.payload()) {
    return { answers: save.response.answers, ratings: save.response.section_ratings }
  }

  storeDraft() {
    if (this.formTarget.inert) return
    this.draft.store(this.onScreen())
  }

  settleDraft(data) {
    if (this.draft.settle(data?.draft_token, this.onScreen())) this.storeDraft()
  }

  nextSave() {
    if (this.formTarget.inert || this.submitHeld) return null
    const save = this.payload()
    this.draft.recordSend(this.onScreen(save))
    return save
  }

  isAnswered(textarea) {
    return this.answered.has(textarea.dataset.field)
  }

  applyServerState(data) {
    if (!Array.isArray(data?.answered_sections)) return
    this.answered = new Set(data.answered_sections)
    this.blocker = data.submit_blocker || null
    this.answersConfirmed = true
    this.updateSubmit()
    this.updateHints()
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

  updateHints() {
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
    return { response: Object.assign({ answers: answers, section_ratings: { ...this.ratings }, draft_scope: this.draftScopeValue,
      manifest_revision: this.manifestRevisionValue }, extra || {}) }
  }

  reconcileStructure(data) {
    if (data.draft_scope !== this.draftScopeValue || data.manifest_revision < this.manifestRevisionValue || this.formTarget.inert) return false
    for (const key of data.section_keys) {
      if (this.sectionsTarget.querySelector(`[data-section-fold="${key}"]`)) continue
      const html = data.cards?.[key]
      if (!html) return false
      this.sectionsTarget.insertAdjacentHTML("beforeend", html)
      if (data.answered_sections?.includes(key)) this.answered.add(key)
      else this.answered.delete(key)
      this.element.dispatchEvent(new CustomEvent("code-gym:sections-added", { bubbles: true }))
      this.formTarget.querySelectorAll(`button.rating-btn.active[data-rating-for="${key}"]`).forEach((button) => {
        this.ratings[key] = button.dataset.rating
      })
    }
    this.textareas = [...this.formTarget.querySelectorAll("textarea[data-field]")]
    const expanded = this.manifestRevisionValue !== data.manifest_revision
    this.manifestRevisionValue = data.manifest_revision
    if (expanded && this.answersConfirmed && this.blocker === null) {
      this.blocker = data.submit_blocker || null
      this.refreshNudge()
    }
    this.updateHints()
    if (expanded) window.CodeGymBootstrap.controllersReady().then(() => this.refreshConnectedControls())
    return true
  }

  additionState(pending) {
    this.additionPending = pending
    this.updateSubmit()
    this.setReplaceButtonsDisabled(pending || this.formTarget.inert)
  }

  updateSubmit() {
    this.submitButtonTarget.disabled = !this.answersConfirmed || this.blocker !== null ||
      Boolean(this.additionPending || this.submitHeld || this.formTarget.inert) || !this.formControllersConnected()
  }

  invalidateReadiness() {
    this.answersConfirmed = false
    this.updateSubmit()
  }

  refreshAdditions() {
    this.element.dispatchEvent(new CustomEvent("answer-form:structure-needed"))
  }

  sendSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    if (this.formTarget.inert) return
    this.invalidateReadiness()
    this.storeDraft()
    if (this.submitHeld) {
      this.heldEdits = true
      return
    }
    saveStatus.queue("answers", "POST", this.formTarget.action, () => this.nextSave(), { latest: true, offline: () => this.offlineSentence() })
      .then(({ ok, status, data, skipped }) => {
        if (skipped || this.submitHeld) return
        if (ok) this.settleSubmitFailure()
        if (ok) this.settleDraft(data)
        if (ok && data?.manifest_revision > this.manifestRevisionValue) this.refreshAdditions()
        if (!ok && status === 409 && data?.status === "stale") {
          this.draft.clearOwn()
          if (this.bannerTookStale(data, "answers")) return this.stopSavingBehindBanner()
          saveStatus.carry("answers", this.staleReloadedValue)
          return this.reloadWhenOtherSavesLand()
        }
        if (ok && data?.submitted && !this.formTarget.inert && !this.reviewRequested) {
          this.draft.discard()
          return this.reloadWhenOtherSavesLand()
        }
        if (ok && this.saveTimer === null && !saveStatus.queued("answers") && !this.formTarget.inert) {
          if (data?.manifest_revision < this.manifestRevisionValue) this.autoSave()
          else if (data?.manifest_revision === this.manifestRevisionValue) this.applyServerState(data)
        }
      })
  }

  reloadWhenOtherSavesLand() {
    this.leaveWhenOtherSavesLand(() => window.location.reload())
  }

  leaveWhenOtherSavesLand(leave, ...ignored) {
    this.submitHeld = true
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    if (!this.formTarget.inert) this.freezeAnswers()
    return saveStatus.leaveWhenSaved(() => this.relockAndLeave(leave), () => this.holdForOtherSaves(), "answers", ...ignored)
  }

  bannerTookStale(data, ...ignored) {
    const stale = new CustomEvent("code-gym:stale-save", { cancelable: true, detail: { banner: data?.banner, ignored: ignored } })
    return !window.dispatchEvent(stale)
  }

  stopSavingBehindBanner() {
    this.heldEdits ||= !this.answersConfirmed
    this.submitHeld = true
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    this.updateSubmit()
  }

  discardDraft() {
    this.stopSavingBehindBanner()
    this.draft.clearOwn()
    this.heldEdits = false
  }

  showStaleSubmitBehindBanner(result) {
    this.draft.clearOwn()
    saveStatus.report("submit", result.message)
    this.unlock()
    this.stopSavingBehindBanner()
  }

  relockAndLeave(leave) {
    this.formTarget.querySelectorAll("dialog[open]").forEach((dialog) => dialog.close())
    this.formTarget.inert = true
    this.element.dispatchEvent(new CustomEvent("answer-form:submission-state"))
    leave()
  }

  leaveAfterSubmit(result, stale) {
    this.startReview(result) || this.reloadAfterSubmit(result, stale)
  }

  autoSave() {
    this.invalidateReadiness()
    this.storeDraft()
    if (this.submitHeld) {
      this.heldEdits = true
      return
    }
    clearTimeout(this.saveTimer)
    this.saveTimer = this.formTarget.inert ? null : setTimeout(() => this.sendSave(), AUTOSAVE_DELAY_MS)
  }

  change(event) {
    if (!this.answersConfirmed && event.target.closest("[data-field], [data-comparison-answer]")) this.sendSave()
  }

  input(event) {
    const field = event.target.closest("textarea[data-field], [data-comparison-answer]")
    if (!field) return
    if (field.dataset.field) this.reopenIfRated(field.dataset.field)
    this.autoSave()
  }

  reopenIfRated(section) {
    const fold = this.formTarget.querySelector(`details.section[data-section-fold="${section}"]`)
    if (fold && !fold.open && this.ratings[section]) fold.open = true
  }

  rate(event) {
    const button = event.target.closest("button[data-rating-for]")
    if (!button) return
    const rating = this.ratings[button.dataset.ratingFor] === button.dataset.rating ? null : button.dataset.rating
    this.showRating(button.dataset.ratingFor, rating)
    this.sendSave()
  }

  showRating(section, rating) {
    const buttons = [...this.formTarget.querySelectorAll(`button[data-rating-for="${section}"]`)]
    const chosen = buttons.find((button) => button.dataset.rating === rating)
    if (rating !== null && !chosen) return
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
    if (this.submitButtonTarget.disabled || this.formTarget.inert || this.additionPending || this.submitHeld) return
    this.lockForSubmit()

    // A kind whose answer only reaches the hidden field through its own controller would otherwise submit the stale one.
    await window.CodeGymBootstrap?.ready
    if (!this.formControllersConnected()) {
      saveStatus.report("submit", this.controlsNotReadyValue)
      return this.unlock()
    }
    const note = await this.flushPendingNote()
    if (note.status === 409) {
      if (this.bannerTookStale(note.data, "submit", "learner_note")) return this.showStaleSubmitBehindBanner(note)
      return this.leaveWhenOtherSavesLand(() => this.reloadAfterSubmit(note, true), "submit", "learner_note")
    }
    if (!note.ok) return this.unlock()

    const result = await request.send("POST", this.formTarget.action, this.payload({ submit: "1" }), { fallback: this.submitFailedValue })
    if (result.status === 409 && ["manifest_changed", "addition_busy"].includes(result.data?.status)) {
      this.unlock()
      this.refreshAdditions()
      saveStatus.report("submit", result.message)
      return
    }
    if (result.ok) saveStatus.clear("submit")
    if (result.ok) this.draft.discard()
    const stale = result.status === 409
    if (stale && this.bannerTookStale(result.data)) return this.showStaleSubmitBehindBanner(result)
    if (result.ok || stale) return this.leaveWhenOtherSavesLand(() => this.leaveAfterSubmit(result, stale), "submit")

    const refused = result.status === 422 && Boolean(result.data?.submit_blocker)
    if (refused) {
      saveStatus.clear("submit")
      this.applyServerState(result.data)
    } else {
      this.offlineSubmit = result.status === 0
      saveStatus.report("submit", (this.offlineSubmit && this.draft.kept) ? this.submitOfflineValue : result.message)
    }
    this.unlock()
    if (refused) this.nudgeTarget.focus()
  }

  offlineSentence() {
    if (!this.draft.kept) return null
    return this.offlineSubmit ? this.submitOfflineValue : this.savingOfflineValue
  }

  settleSubmitFailure() {
    this.offlineSubmit = false
    saveStatus.clear("submit")
  }

  formControllersConnected() {
    return [...this.formTarget.querySelectorAll("[data-controller]")].every((element) =>
      element.dataset.controller.split(/\s+/).filter(Boolean).every((identifier) =>
        this.application.getControllerForElementAndIdentifier(element, identifier)))
  }

  async flushPendingNote() {
    const element = this.element.querySelector('[data-controller~="learner-note"]')
    if (!element) return { ok: true }
    const note = this.application.getControllerForElementAndIdentifier(element, "learner-note")
    if (note) return note.flush()
    saveStatus.report("submit", this.controlsNotReadyValue)
    return { ok: false }
  }

  lockForSubmit() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    this.formTarget.inert = true
    this.element.dispatchEvent(new CustomEvent("answer-form:submission-state"))
    this.element.querySelector("#learner-note")?.toggleAttribute("inert", true)
    this.submitButtonTarget.disabled = true
    this.setReplaceButtonsDisabled(true)
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
  reloadAfterSubmit(result, stale) {
    if (!result.ok && !stale) return false
    this.draft.clearOwn()
    saveStatus.carry("answers", result.ok ? this.reviewStartFailedValue : this.staleReloadedValue)
    window.location.reload()
    return true
  }

  // Answers stay read-only, since the server would drop any edit now; the swap rows stay usable so the held save can land.
  freezeAnswers() {
    this.formTarget.inert = false
    this.formTarget.querySelectorAll(":scope > *, details.section > *").forEach((element) => {
      if (element !== this.sectionsTarget && !element.matches("details.section, summary, .daily-kind-swap")) element.inert = true
    })
    this.submitButtonTarget.disabled = true
    this.setReplaceButtonsDisabled(true)
  }

  setReplaceButtonsDisabled(disabled) {
    this.replaceButtonTargets.forEach((button) => button.disabled = disabled)
  }

  holdForOtherSaves() {
    this.freezeAnswers()
    this.submitButtonTarget.classList.remove("btn-loading")
    this.submitButtonTarget.textContent = this.submitLabelValue
    this.showHeldNotice()
  }

  showHeldNotice() {
    if (this.element.querySelector("#leave-held")) return
    const notice = document.createElement("p")
    notice.className = "hint"
    notice.id = "leave-held"
    notice.setAttribute("role", "status")
    notice.textContent = `${this.leaveHeldValue} `
    const reload = document.createElement("button")
    reload.type = "button"
    reload.className = "btn btn-ghost btn-sm"
    reload.textContent = this.reloadNowValue
    reload.addEventListener("click", () => window.location.reload())
    notice.append(reload)
    this.formTarget.after(notice)
    notice.scrollIntoView({ block: "nearest" })
  }

  unlock() {
    this.formTarget.inert = false
    this.element.dispatchEvent(new CustomEvent("answer-form:submission-state"))
    this.element.querySelector("#learner-note")?.toggleAttribute("inert", false)
    this.submitButtonTarget.classList.remove("btn-loading")
    this.submitButtonTarget.textContent = this.submitLabelValue
    this.invalidateReadiness()
    this.setReplaceButtonsDisabled(Boolean(this.additionPending))
    this.autoSave()
  }
}
