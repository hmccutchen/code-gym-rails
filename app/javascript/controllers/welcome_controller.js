// Design notes: docs/code-notes/app/javascript/controllers/welcome_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["choice"]

  static values = {
    url: String,
    setupUrl: String,
    preset: Object,
    skillLevel: String,
    version: Number
  }

  userFor(choice) {
    if (choice !== "junior") return { learning_track: "none" }

    return { learning_track: "junior",
             section_kind_levels: this.presetValue,
             skill_level: this.skillLevelValue,
             section_kind_preferences_version: this.versionValue }
  }

  setBusy(busy) {
    this.choiceTargets.forEach((button) => { button.disabled = busy })
  }

  async choose(event) {
    this.setBusy(true)
    const user = this.userFor(event.currentTarget.dataset.track)
    const result = await saveStatus.save("PATCH", this.urlValue, { user }, "learning_track")

    if (result && result.ok) window.location = this.setupUrlValue
    else this.setBusy(false)
  }
}
