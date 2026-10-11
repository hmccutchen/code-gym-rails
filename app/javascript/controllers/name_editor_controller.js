// Design notes: docs/code-notes/app/javascript/controllers/name_editor_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

const FLASH_MS = 2000

export default class extends Controller {
  static targets = ["input", "status"]

  static values = { url: String, savedText: String, errorText: String }

  connect() {
    this.lastSaved = this.inputTarget.defaultValue
    if (this.inputTarget.value !== this.lastSaved) this.save()
  }

  disconnect() {
    clearTimeout(this.statusTimer)
  }

  async save() {
    const name = this.inputTarget.value.trim()
    if (name === this.lastSaved) return
    if (name === "") return (this.inputTarget.value = this.lastSaved)

    const { ok, data } = await saveStatus.queue("name", "PATCH", this.urlValue,
      () => ({ user: { name: this.inputTarget.value.trim() || name } }), { latest: true, quiet: true })
    const saved = ok && typeof data?.name === "string"
    if (saved) this.lastSaved = data.name
    if (saveStatus.queued("name")) return

    if (saved) {
      this.inputTarget.value = data.name
      this.flash(this.savedTextValue)
    } else {
      this.inputTarget.value = this.lastSaved
      this.flash(this.errorTextValue)
    }
  }

  flash(message) {
    this.statusTarget.textContent = message
    clearTimeout(this.statusTimer)
    this.statusTimer = setTimeout(() => { this.statusTarget.textContent = "" }, FLASH_MS)
  }
}
