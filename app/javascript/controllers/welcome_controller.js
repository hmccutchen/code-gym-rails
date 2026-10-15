// Design notes: docs/code-notes/app/javascript/controllers/welcome_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["choice", "experienced", "trackStep", "levelStep", "levelHeading"]

  static values = {
    url: String,
    setupUrl: String,
    preset: Object,
    skillLevel: String,
    version: Number
  }

  juniorTrack() {
    return { learning_track: "junior",
             section_kind_levels: this.presetValue,
             skill_level: this.skillLevelValue,
             section_kind_preferences_version: this.versionValue }
  }

  setBusy(busy) {
    this.choiceTargets.forEach((button) => { button.disabled = busy })
  }

  showLevels() {
    this.trackStepTarget.hidden = true
    this.levelStepTarget.hidden = false
    this.levelHeadingTarget.focus()
  }

  back() {
    this.levelStepTarget.hidden = true
    this.trackStepTarget.hidden = false
    this.experiencedTarget.focus()
  }

  choose() {
    this.save(this.juniorTrack())
  }

  chooseLevel(event) {
    this.save({ learning_track: "none", skill_level: event.currentTarget.dataset.level })
  }

  async save(user) {
    const pressed = document.activeElement
    this.setBusy(true)
    const result = await saveStatus.save("PATCH", this.urlValue, { user }, "learning_track")

    if (result && result.ok) {
      window.location = this.setupUrlValue
    } else {
      this.setBusy(false)
      if (this.choiceTargets.includes(pressed)) pressed.focus()
    }
  }
}
