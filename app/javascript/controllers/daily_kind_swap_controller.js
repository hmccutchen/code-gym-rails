// Design notes: docs/code-notes/app/javascript/controllers/daily_kind_swap_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["panel", "trigger", "picker", "option", "summary", "confirm", "cancel", "status", "reply"]

  static values = { url: String, exercise: Number, draftScope: String, savingText: String }

  connect() {
    this.busy = false
  }

  // Another card's reply re-renders this panel too; a swap still queued here keeps showing as saving.
  panelTargetConnected() {
    if (this.busy) this.setBusy(true)
  }

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
    else this.cancelTarget.focus()
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

  choose() {
    const chosen = this.chosen()
    const available = chosen && chosen.dataset.state === "available"
    this.summaryTargets.forEach((summary) => { summary.hidden = !available || summary.dataset.kind !== chosen.value })
    this.confirmTarget.disabled = this.busy || !available
    const summary = available && this.summaryTargets.find((element) => element.dataset.kind === chosen.value)
    if (summary) this.confirmTarget.setAttribute("aria-describedby", summary.id)
    else this.confirmTarget.removeAttribute("aria-describedby")
  }

  chosen() {
    return this.optionTargets.find((option) => option.checked)
  }

  setBusy(busy) {
    this.busy = busy
    this.confirmTarget.disabled = busy
    this.cancelTarget.disabled = busy
    this.statusTarget.textContent = busy ? this.savingTextValue : ""
  }

  async confirm() {
    const chosen = this.chosen()
    if (this.busy || !chosen || chosen.dataset.state !== "available") return

    this.setBusy(true)
    const kind = chosen.value
    const result = await saveStatus.queue(`daily_kind_swap:${this.urlValue}`, "PATCH", this.urlValue, () => this.body(kind),
      { line: "daily_kind_swap" })
    this.busy = false
    if (result && result.ok && result.data) return this.saved(result.data)
    if (result && result.status === 409 && result.data) return this.refreshStale(result.data)

    this.setBusy(false)
    this.reopenWith(kind)
  }

  reopenWith(kind) {
    const submitted = this.optionTargets.find((option) => option.value === kind)
    if (submitted && submitted.dataset.state === "available") submitted.checked = true
    this.open()
    if (!this.confirmTarget.disabled) this.confirmTarget.focus()
  }

  // Read when the queue sends it, so a swap queued behind another posts the version that one's reply left.
  body(kind) {
    return { kind: kind, exercise_id: this.exerciseValue, draft_scope: this.draftScopeValue,
             section_kind_preferences_version: this.panelTarget.dataset.version }
  }

  saved(data) {
    if (!this.replacePanels(data.panels)) this.leaveCards()
    this.announce(data.message, data.want_it_today, data.want_it_today_link)
    if (data.set_changed) this.replyTarget.append(this.paragraph(data.set_changed))
    this.triggerTarget.focus()
  }

  leaveCards() {
    this.setBusy(false)
    this.close()
  }

  // Another tab changed the pair or the mix, so the picker reopens on the stored pair before the reader tries again.
  refreshStale(data) {
    if (this.replacePanels(data.panels)) return this.open()

    this.leaveCards()
    this.replyTarget.replaceChildren(this.paragraph(data.set_changed || data.error))
  }

  replacePanels(panels) {
    const mine = this.panelTarget
    Object.entries(panels || {}).forEach(([place, html]) => {
      const panel = document.getElementById(`daily-kind-swap-panel-${place}`)
      if (panel) panel.outerHTML = html
    })
    return !mine.isConnected
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
