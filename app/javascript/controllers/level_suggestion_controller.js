// Design notes: docs/code-notes/app/javascript/controllers/level_suggestion_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["step", "apply", "setupLink", "notNow"]

  static values = {
    levels: Object,
    version: Number,
    url: String,
    dismissUrl: String,
    answerUrl: String,
    appliedText: String,
    dismissedText: String,
    countFailedText: String,
    strandedText: String,
    reloadLabel: String
  }

  listed() {
    return this.stepTargets.filter((element) => !element.hidden)
  }

  removed() {
    return this.stepTargets.filter((element) => element.hidden)
  }

  // The server checks each from against the stored level and refuses a card the levels have moved past.
  shown(elements) {
    return elements.map((element) => ({ kind: element.dataset.kind, from: element.dataset.from, to: element.dataset.to }))
  }

  setBusy(busy) {
    this.element.querySelectorAll("button").forEach((button) => { button.disabled = busy })
    if (this.hasApplyTarget) this.applyTarget.disabled = busy || this.listed().length === 0
    if (this.hasSetupLinkTarget) this.setupLinkTarget.inert = busy
  }

  // The buttons that had focus are gone, so the confirmation takes it and a screen reader reads it out.
  settle(text, ...extra) {
    const line = document.createElement("p")
    line.setAttribute("role", "status")
    line.tabIndex = -1
    line.textContent = text
    this.element.replaceChildren(line, ...extra)
    line.focus()
  }

  // A hung save is not reloaded over, but a refused proposal must not stay stuck: the reload becomes the user's call.
  stranded() {
    const reload = document.createElement("button")
    reload.type = "button"
    reload.className = "btn btn-ghost btn-sm"
    reload.textContent = this.reloadLabelValue
    reload.addEventListener("click", () => window.location.reload())
    this.settle(this.strandedTextValue, reload)
  }

  reloadWhenSaved() {
    saveStatus.reloadWhenSaved(() => this.stranded())
  }

  answer() {
    return saveStatus.save("POST", this.answerUrlValue, {}, "level_answer", this.countFailedTextValue)
  }

  dismiss(elements, reason) {
    if (elements.length === 0) return Promise.resolve({ ok: true })
    const kinds = elements.map((element) => element.dataset.kind)
    return saveStatus.save("POST", this.dismissUrlValue, { kinds, reason, steps: this.shown(elements) }, "level_dismissal")
  }

  removeStep(event) {
    event.currentTarget.closest("[data-level-suggestion-target~='step']").hidden = true
    this.applyTarget.disabled = this.listed().length === 0
  }

  async apply() {
    this.setBusy(true)
    const levels = Object.assign({}, this.levelsValue)
    this.listed().forEach((element) => { levels[element.dataset.kind] = element.dataset.to })
    const setAside = this.removed()
    const result = await saveStatus.save("PATCH", this.urlValue,
      { user: { section_kind_levels: levels, section_kind_preferences_version: this.versionValue },
        level_suggestion_steps: this.shown(this.listed()) },
      "level_apply")

    if (result && result.ok) {
      this.settle(this.appliedTextValue)
      this.answer()
      this.dismiss(setAside, "removed")
      return
    }
    if (result && result.status === 409) return this.reloadWhenSaved()
    this.setBusy(false)
  }

  async notNow() {
    this.setBusy(true)
    const result = await this.dismiss(this.stepTargets, "not_now")
    if (result && result.status === 409) return this.reloadWhenSaved()
    if (!result || !result.ok) return this.setBusy(false)
    this.answer()
    this.settle(this.dismissedTextValue)
  }
}
