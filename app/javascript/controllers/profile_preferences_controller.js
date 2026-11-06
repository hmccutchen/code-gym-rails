// Design notes: docs/code-notes/app/javascript/controllers/profile_preferences_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"
import trackReply from "code_gym/track_reply"

export default class extends Controller {
  static targets = ["timeZone", "skillLevel", "keptOwnLevel", "trackPanel", "preview", "trackStatus", "apply", "cancel", "refresh"]

  static values = {
    url: String,
    previewUrl: String,
    labelTemplate: String,
    loadingText: String,
    unsavedText: String,
    waitingText: String,
    staleText: String,
    savingText: String,
    unconfirmedText: String
  }

  // An edit made before this controller connected fires no event of its own, so adopt it against what the server rendered.
  connect() {
    this.sequence = 0
    this.savedLevel = this.renderedValue(this.skillLevelTarget)
    this.proposing = false
    this.writing = false
    if (this.timeZoneTarget.value !== this.renderedValue(this.timeZoneTarget)) this.saveTimeZone()
    if (this.skillLevelTarget.value !== this.renderedValue(this.skillLevelTarget)) this.saveSkillLevel()
  }

  disconnect() {
    this.sequence++
    this.proposing = false
  }

  renderedValue(select) {
    return Array.from(select.options).find((option) => option.defaultSelected)?.value
  }

  // Key per control: all controls PATCH one path, and a shared key lets one success clear another's warning.
  queueSave(key, payload, options) {
    return saveStatus.queue(key, "PATCH", this.urlValue, { user: payload }, options)
  }

  saveTimeZone() {
    this.queueSave("time_zone", { time_zone: this.timeZoneTarget.value })
  }

  saveSkillLevel() {
    if (this.writing) return
    this.proposing = true
    this.previewTrack()
  }

  mixEdited(event) {
    if (!this.proposing || !event.target.closest("[data-exercise-mix-target~='row'], [data-exercise-mix-target~='difficulty']")) return
    this.sequence++
    this.confirmation = null
    this.applyTarget.disabled = true
    if (!this.writing) this.previewTrack()
  }

  currentPreview(sequence) {
    return this.proposing && this.sequence === sequence && this.element.isConnected
  }

  async previewTrack(notice = "") {
    const sequence = ++this.sequence
    const level = this.skillLevelTarget.value
    this.confirmation = null
    this.trackPanelTarget.hidden = false
    this.previewTarget.innerHTML = ""
    this.trackStatusTarget.textContent = this.loadingTextValue
    this.applyTarget.disabled = true
    this.refreshTarget.disabled = true
    // Let sibling controllers adopt pre-connect edits before their pending probes are read.
    await Promise.resolve()
    const ready = await saveStatus.settled("track_preview", "skill_level")
    if (!this.currentPreview(sequence)) return
    if (!ready) return this.previewFailed(this.waitingTextValue)

    const result = await saveStatus.queue("track_preview", "POST", this.previewUrlValue,
      () => this.currentPreview(sequence) ? { user: { skill_level: level } } : null,
      { line: "exercise_mix", quiet: true })
    if (!this.currentPreview(sequence)) return
    if (!result.ok || !this.previewReply(result.data, level)) return this.previewFailed(result.message)

    saveStatus.clear("track_preview")
    saveStatus.clear("skill_level")
    this.previewTarget.innerHTML = result.data.preview_html
    this.confirmation = result.data.track_change
    this.updateSavedBaseline(result.data.skill_level)
    this.refreshTarget.disabled = false
    this.applyTarget.disabled = result.data.already_saved
    this.trackStatusTarget.textContent = [notice, result.data.already_saved ? "" : this.unsavedTextValue].filter(Boolean).join(" ")
    if (result.data.already_saved) {
      trackReply.start()
      this.adoptSaved(result.data)
    }
  }

  savedState(data) {
    return data?.preferences?.ladder_preparation && data.kind_rungs &&
      Array.from(this.skillLevelTarget.options).some((option) => option.value === data.skill_level)
  }

  previewReply(data, level) {
    return this.savedState(data) && typeof data.preview_html === "string" && typeof data.already_saved === "boolean" &&
      data.track_change?.to === level && data.track_change.from === data.skill_level &&
      Number.isInteger(data.track_change.preferences_version)
  }

  previewFailed(message) {
    this.trackStatusTarget.textContent = [message, this.unconfirmedTextValue].filter(Boolean).join(" ")
    this.refreshTarget.disabled = false
    saveStatus.report("track_preview", message || this.unconfirmedTextValue)
  }

  refreshPreview() {
    if (!this.writing && this.proposing) this.previewTrack()
  }

  cancelTrack() {
    if (this.writing) return
    this.sequence++
    this.proposing = false
    this.confirmation = null
    this.trackPanelTarget.hidden = true
    this.skillLevelTarget.value = this.savedLevel
    this.dispatch("trackRestored", { target: this.skillLevelTarget })
    saveStatus.clear("track_preview")
    saveStatus.clear("skill_level")
    this.skillLevelTarget.focus({ preventScroll: true })
  }

  async applyTrack() {
    if (this.writing || !this.confirmation || this.applyTarget.disabled) return
    const confirmation = this.confirmation
    const focused = this.element.contains(document.activeElement) ? document.activeElement : null
    this.sequence++
    this.writing = true
    this.setWriting(true)
    this.trackStatusTarget.textContent = this.savingTextValue
    let result
    try {
      result = await this.sendTrack(confirmation)
    } finally {
      this.writing = false
      this.setWriting(false)
      const lost = document.activeElement === null || document.activeElement === document.body
      if (focused && lost) this.skillLevelTarget.focus({ preventScroll: true })
    }
    if (result?.status === 409 && this.proposing) this.previewTrack(this.staleTextValue)
  }

  setWriting(writing) {
    this.skillLevelTarget.disabled = writing
    this.cancelTarget.disabled = writing
    this.refreshTarget.disabled = writing
    this.applyTarget.disabled = true
  }

  async sendTrack(confirmation) {
    trackReply.start()
    this.dispatch("trackSaving", { target: document })
    const result = await saveStatus.queue("skill_level", "PATCH", this.urlValue,
      { user: { skill_level: confirmation.to }, track_change: confirmation }, { line: "exercise_mix" })
    if (!result.ok || !this.savedState(result.data)) {
      trackReply.finish(null)
      this.dispatch("trackFailed", { target: document })
      this.confirmation = null
      this.trackStatusTarget.textContent = [result.message, this.unconfirmedTextValue].filter(Boolean).join(" ")
      saveStatus.report("skill_level", result.message || this.unconfirmedTextValue)
      if (result.data?.skill_level) this.updateSavedBaseline(result.data.skill_level)
      return result
    }

    this.adoptSaved(result.data)
    this.proposing = false
    this.confirmation = null
    this.trackPanelTarget.hidden = true
    return result
  }

  adoptSaved(data) {
    const reply = Object.assign({ kind_rungs: data.kind_rungs }, data.preferences)
    trackReply.finish(reply)
    this.dispatch("trackSaved", { target: document, detail: reply })
    this.keptOwnLevelTarget.textContent = data.kept_own_level
    this.updateSavedBaseline(data.skill_level)
    this.skillLevelTarget.value = this.savedLevel
    this.dispatch("trackRestored", { target: this.skillLevelTarget })
  }

  updateSavedBaseline(level) {
    const option = Array.from(this.skillLevelTarget.options).find((option) => option.value === level)
    if (!option) return
    this.savedLevel = level
    document.querySelectorAll("[data-skill-level-label]").forEach((label) => {
      label.textContent = this.labelTemplateValue.replace("__LEVEL__", option.textContent)
    })
  }
}
