// Design notes: docs/code-notes/app/javascript/controllers/save_switch_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["checkbox", "status"]

  static values = {
    url: String,
    key: String,
    field: String,
    scope: String,
    focus: Boolean,
    savedText: String
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
    if (this.hasStatusTarget) this.statusTarget.textContent = ""
    const result = await saveStatus.queue(this.keyValue, "PATCH", this.urlValue, this.body(wanted))
    if (result.ok) this.saved = wanted
    if (result.ok && !saveStatus.queued(this.keyValue) && this.hasStatusTarget) this.statusTarget.textContent = this.savedTextValue
    if (!saveStatus.queued(this.keyValue)) this.checkboxTarget.checked = this.saved
  }

  body(wanted) {
    const fields = { [this.fieldValue]: wanted }
    return this.scopeValue ? { [this.scopeValue]: fields } : fields
  }
}
