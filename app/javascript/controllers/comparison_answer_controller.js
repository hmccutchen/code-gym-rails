// Design notes: docs/code-notes/app/javascript/controllers/comparison_answer_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "reason", "pick"]

  static values = { prefix: String }

  // Both controls are editable before this module loads, so adopt anything already typed or picked.
  connect() {
    const picked = this.pickTargets.some((radio) => radio.checked !== radio.defaultChecked)
    if (picked || this.reasonTarget.value !== this.reasonTarget.defaultValue) this.compose()
  }

  // Matches DesignComparison.encode_answer; a reason with no pick keeps its line so a reload shows it.
  compose() {
    const pick = this.pickTargets.find((radio) => radio.checked)?.value
    const prefix = pick ? this.prefixValue + pick : ""
    const reason = this.reasonTarget.value
    this.fieldTarget.value = pick || reason.trim() ? `${prefix}\n${reason}` : ""
    this.fieldTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
