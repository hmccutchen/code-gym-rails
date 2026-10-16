// Design notes: docs/code-notes/app/javascript/controllers/welcome_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["choice"]

  static values = {
    url: String,
    setupUrl: String
  }

  setBusy(busy) {
    this.choiceTargets.forEach((button) => { button.disabled = busy })
  }

  async choose(event) {
    const pressed = event.currentTarget
    this.setBusy(true)
    const user = { choose_track: true, skill_level: pressed.dataset.level }
    const result = await saveStatus.save("PATCH", this.urlValue, { user }, "track_choice")

    if (result && result.ok) {
      window.location = this.setupUrlValue
    } else {
      this.setBusy(false)
      pressed.focus()
    }
  }
}
