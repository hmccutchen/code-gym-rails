// Design notes: docs/code-notes/app/javascript/controllers/learning_track_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["suggestions", "leaveButton"]

  static values = {
    url: String,
    leftText: String
  }

  connect() {
    this.savedSuggestions = this.suggestionsTarget.defaultChecked
    if (this.suggestionsTarget.checked !== this.savedSuggestions) this.toggleSuggestions()
  }

  async toggleSuggestions() {
    const wanted = this.suggestionsTarget.checked
    const result = await saveStatus.queue("track_suggestions", "PATCH", this.urlValue,
                                          { user: { track_suggestions: wanted } })
    if (result.ok) this.savedSuggestions = wanted
    if (!saveStatus.queued("track_suggestions")) this.suggestionsTarget.checked = this.savedSuggestions
  }

  async leave() {
    const button = this.leaveButtonTarget
    button.disabled = true
    const result = await saveStatus.save("PATCH", this.urlValue, { user: { learning_track: "none" } }, "learning_track")
    // Settles in place: a reload could cancel the Exercise mix's delayed save or hide its failure.
    if (!result || !result.ok) {
      button.disabled = false
      return
    }

    // The key guide renders only for a track user.
    document.querySelector(".key-guide")?.remove()
    const line = document.createElement("p")
    line.className = "hint"
    line.setAttribute("role", "status")
    line.tabIndex = -1
    line.textContent = this.leftTextValue
    this.element.replaceChildren(line)
    // The button that had focus is gone, so the confirmation takes it.
    line.focus()
  }
}
