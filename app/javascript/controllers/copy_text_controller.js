// Design notes: docs/code-notes/app/javascript/controllers/copy_text_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "status"]

  static values = { copiedText: String, selectedText: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.innerText.trim())
      this.statusTarget.textContent = this.copiedTextValue
    } catch {
      this.selectSource()
      this.statusTarget.textContent = this.selectedTextValue
    }
  }

  selectSource() {
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }
}
