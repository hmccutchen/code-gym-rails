// Design notes: docs/code-notes/app/javascript/controllers/value_row_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["value"]

  connect() {
    this.show()
  }

  show() {
    const select = this.element.querySelector("select")
    this.valueTarget.textContent = select.selectedOptions[0]?.text ?? ""
  }
}
