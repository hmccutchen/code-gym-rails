import { Controller } from "@hotwired/stimulus"

// Inline nav name field. Autosaves to PATCH /profile when the input loses
// focus, reverting on blank or failure. All user-visible copy comes from
// data-*-value attributes so no strings live in JS.
export default class extends Controller {
  static targets = ["input", "status"]
  static values = { url: String, savedText: String, errorText: String }

  connect() {
    this.lastSaved = this.inputTarget.value
  }

  async save() {
    const name = this.inputTarget.value.trim()

    if (name === this.lastSaved) return

    if (name === "") {
      this.inputTarget.value = this.lastSaved
      return
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
        },
        body: JSON.stringify({ user: { name } })
      })

      if (response.ok) {
        const data = await response.json()
        this.inputTarget.value = data.name
        this.lastSaved = data.name
        this.flash(this.savedTextValue)
      } else {
        this.inputTarget.value = this.lastSaved
        this.flash(this.errorTextValue)
      }
    } catch {
      this.inputTarget.value = this.lastSaved
      this.flash(this.errorTextValue)
    }
  }

  flash(message) {
    this.statusTarget.textContent = message
    clearTimeout(this.flashTimer)
    this.flashTimer = setTimeout(() => { this.statusTarget.textContent = "" }, 2000)
  }
}
