// Design notes: docs/code-notes/app/javascript/controllers/daily_kind_swap_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["panel", "trigger", "picker", "option", "summary", "confirm", "cancel", "status", "reply"]

  static values = { url: String, savingText: String }

  toggle() {
    if (this.pickerTarget.hidden) this.open()
    else this.close()
  }

  open() {
    this.pickerTarget.hidden = false
    this.triggerTarget.setAttribute("aria-expanded", "true")
    this.choose()
    const checked = this.optionTargets.find((option) => option.checked)
    if (checked) checked.focus()
  }

  close() {
    this.pickerTarget.hidden = true
    this.triggerTarget.setAttribute("aria-expanded", "false")
    this.triggerTarget.focus()
  }

  cancel() {
    this.optionTargets.forEach((option) => { option.checked = option.dataset.state === "now" })
    this.close()
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return
    event.preventDefault()
    this.cancel()
  }

  // The server rendered each option's consequences; the page only shows the one for the chosen kind.
  choose() {
    const chosen = this.chosen()
    const available = chosen && chosen.dataset.state === "available"
    this.summaryTargets.forEach((summary) => { summary.hidden = !available || summary.dataset.kind !== chosen.value })
    this.confirmTarget.disabled = !available
    const summary = available && this.summaryTargets.find((element) => element.dataset.kind === chosen.value)
    if (summary) this.confirmTarget.setAttribute("aria-describedby", summary.id)
    else this.confirmTarget.removeAttribute("aria-describedby")
  }

  chosen() {
    return this.optionTargets.find((option) => option.checked)
  }

  setBusy(busy) {
    this.confirmTarget.disabled = busy
    this.cancelTarget.disabled = busy
    this.statusTarget.textContent = busy ? this.savingTextValue : ""
  }

  async confirm() {
    const chosen = this.chosen()
    if (!chosen || chosen.dataset.state !== "available") return

    this.setBusy(true)
    const result = await saveStatus.save("PATCH", this.urlValue,
      { kind: chosen.value, section_kind_preferences_version: this.panelTarget.dataset.version },
      "daily_kind_swap")
    if (result && result.ok && result.data) return this.saved(result.data)

    this.setBusy(false)
    this.choose()
    this.confirmTarget.focus()
  }

  saved(data) {
    Object.entries(data.panels || {}).forEach(([place, html]) => {
      const panel = document.getElementById(`daily-kind-swap-panel-${place}`)
      if (panel) panel.outerHTML = html
    })
    this.announce(data.message, data.want_it_today, data.want_it_today_link)
    if (this.hasTriggerTarget) this.triggerTarget.focus()
  }

  announce(message, wantItToday, linkLabel) {
    this.replyTarget.replaceChildren(this.paragraph(message))
    if (!wantItToday) return

    const line = this.paragraph(wantItToday)
    const link = document.createElement("a")
    link.href = "#"
    link.textContent = linkLabel
    link.addEventListener("click", (event) => this.focusRegenerate(event))
    line.append(" ", link)
    this.replyTarget.append(line)
  }

  paragraph(text) {
    const line = document.createElement("p")
    line.className = "hint"
    line.textContent = text
    return line
  }

  // The existing button keeps its own confirm and cost, so the link only takes the reader to it.
  focusRegenerate(event) {
    event.preventDefault()
    const button = document.querySelector(".regenerate-row form button")
    if (!button) return
    button.scrollIntoView({ block: "center" })
    button.focus()
  }
}
