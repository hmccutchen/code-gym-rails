// Design notes: docs/code-notes/app/javascript/controllers/level_suggestions_switch_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["checkbox"]

  static values = {
    url: String,
    focus: Boolean
  }

  connect() {
    this.saved = this.checkboxTarget.defaultChecked
    if (this.checkboxTarget.checked !== this.saved) this.toggle()
    if (this.focusValue) this.bringIntoView()
  }

  bringIntoView() {
    this.element.scrollIntoView({ block: "center" })
    this.checkboxTarget.focus()
  }

  async toggle() {
    const wanted = this.checkboxTarget.checked
    const result = await saveStatus.queue("level_suggestions", "PATCH", this.urlValue,
                                          { user: { level_suggestions: wanted } })
    if (result.ok) this.saved = wanted
    if (!saveStatus.queued("level_suggestions")) this.checkboxTarget.checked = this.saved
  }
}
