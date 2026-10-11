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
    if (name === "") return this.revert()
    this.reverted = null

    let sent = null
    const { ok, data } = await saveStatus.queue("name", "PATCH", this.urlValue,
      () => { sent = this.inputTarget.value.trim() || name; return { user: { name: sent } } }, { latest: true, quiet: true })
    const saved = ok && typeof data?.name === "string"
    if (saved) this.lastSaved = data.name
    if (saveStatus.queued("name")) return

    // The field stays editable while the request is out, so only the text this save posted may be written over.
    const current = this.inputTarget.value.trim()
    const unchanged = sent !== null && (current === sent || current === this.reverted)
    if (saved) {
      if (unchanged) this.inputTarget.value = data.name
      this.flash(this.savedTextValue)
    } else {
      if (unchanged) this.inputTarget.value = this.lastSaved
      this.flash(this.errorTextValue)
    }
  }

  revert() {
    this.inputTarget.value = this.reverted = this.lastSaved
  }

  flash(message) {
    this.statusTarget.textContent = message
    clearTimeout(this.statusTimer)
    this.statusTimer = setTimeout(() => { this.statusTarget.textContent = "" }, FLASH_MS)
  }
}
