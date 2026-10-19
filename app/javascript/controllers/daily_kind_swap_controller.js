// Design notes: docs/code-notes/app/javascript/controllers/daily_kind_swap_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

let lastConfirmed = null

export default class extends Controller {
  static targets = ["panel", "trigger", "sheet", "choosing", "picker", "option", "example", "consequences", "saved",
                    "savedMessage", "savedOffer", "error", "confirm", "done", "cancel", "close", "status", "reply"]

  static values = { url: String, exercise: Number, draftScope: String, savingText: String }

  connect() {
    this.busy = false
    this.attempted = null
    this.wanted = false
    this.savedReply = null
    this.failedReply = null
  }

  // Any reply re-renders this panel; a kept failure, a sheet that was open (data-sheet-open) and a queued swap's saving state come back.
  panelTargetConnected() {
    const reopen = this.panelTarget.dataset.sheetOpen === "true"
    delete this.panelTarget.dataset.sheetOpen
    if (!reopen && !this.sheetTarget.open) this.wanted = false
    if (this.busy) this.setBusy(true)
    else this.reconcile()
    this.restoreFailure()
    if (reopen && this.wanted && this.sheetMayOpen()) this.reshow()
  }

  reconcile() {
    if (!this.attempted || this.panelTarget.dataset.current !== this.attempted) return false

    this.attempted = null
    this.failedReply = null
    saveStatus.clear(this.statusKey)
    return true
  }

  restoreFailure() {
    if (!this.failedReply) return

    const kept = this.optionTargets.find((option) => option.value === this.failedReply.kind)
    if (kept && kept.dataset.state === "available") kept.checked = true
    this.errorTarget.textContent = this.failedReply.message
    this.choose()
  }

  // A modal inside an inert ancestor would cover the page with nothing in it reachable.
  sheetMayOpen() {
    return !this.element.closest("[inert]")
  }

  replyMayShowSheet() {
    return this.wanted && this.replyMayFocus && this.sheetMayOpen()
  }

  open() {
    this.wanted = true
    this.savedReply = null
    this.showSaved(false)
    if (!this.sheetTarget.open) this.sheetTarget.showModal()
    this.choose()
    this.focusChoice()
  }

  reshow() {
    if (this.savedReply) return this.showSavedSheet()

    this.sheetTarget.showModal()
    this.choose()
    if (!this.busy) this.focusChoice()
  }

  focusChoice() {
    const checked = this.chosen()
    if (checked) checked.focus()
    else this.closeTarget.focus()
  }

  hide(focus = true) {
    this.wanted = false
    if (this.sheetTarget.open) this.sheetTarget.close()
    if (focus) this.triggerTarget.focus()
  }

  dismiss() {
    if (this.busy) return
    this.savedReply = null
    this.resetChoice()
    this.hide()
  }

  resetChoice() {
    this.failedReply = null
    this.optionTargets.forEach((option) => { option.checked = option.dataset.state === "now" })
    this.errorTarget.textContent = ""
  }

  escape(event) {
    event.preventDefault()
    this.dismiss()
  }

  // Chrome closes a sheet on a second Escape even when the first was refused; a swap still saving keeps its choice for the reply.
  closed(event) {
    if (!event.target.isConnected || event.target.open || !this.wanted) return

    this.wanted = false
    this.savedReply = null
    if (!this.busy) this.resetChoice()
    this.triggerTarget.focus()
  }

  press(event) {
    this.pressedSheet = event.target === this.sheetTarget
  }

  backdrop(event) {
    const fromBackdrop = this.pressedSheet && event.target === this.sheetTarget
    this.pressedSheet = false
    if (fromBackdrop) this.dismiss()
  }

  choose() {
    const chosen = this.chosen()
    const available = Boolean(chosen) && chosen.dataset.state === "available"
    const block = available && this.consequencesTargets.find((element) => element.dataset.kind === chosen.value)
    this.exampleTargets.forEach((example) => { example.hidden = !chosen || example.dataset.kind !== chosen.value })
    this.consequencesTargets.forEach((element) => { element.hidden = element !== block })
    this.confirmTarget.disabled = this.busy || !available
    this.confirmTarget.textContent = available ? chosen.dataset.confirmLabel : this.confirmTarget.dataset.label
    this.describePrimary(block)
  }

  describePrimary(block) {
    const ids = [block && block.id, this.errorTarget.textContent ? this.errorTarget.id : null].filter(Boolean)
    if (ids.length) this.confirmTarget.setAttribute("aria-describedby", ids.join(" "))
    else this.confirmTarget.removeAttribute("aria-describedby")
  }

  chosen() {
    return this.optionTargets.find((option) => option.checked)
  }

  setBusy(busy) {
    this.busy = busy
    this.cancelTarget.disabled = busy
    this.closeTarget.disabled = busy
    if (this.hasPickerTarget) this.pickerTarget.inert = busy
    this.statusTarget.textContent = busy ? this.savingTextValue : ""
    this.choose()
  }

  async confirm() {
    const chosen = this.chosen()
    if (this.busy || !chosen || chosen.dataset.state !== "available") return

    lastConfirmed = this
    this.failedReply = null
    this.errorTarget.textContent = ""
    this.setBusy(true)
    const kind = chosen.value
    const result = await saveStatus.queue(this.statusKey, "PATCH", this.urlValue, () => this.body(kind),
      { line: "daily_kind_swap" })
    this.busy = false
    this.wanted = this.wanted && this.sheetTarget.open
    const before = document.activeElement
    this.replyMayFocus = this.element.contains(before) || ((!before || before === document.body) && lastConfirmed === this)
    this.attempted = result && result.ok ? null : kind
    if (result && result.ok && result.data) return this.saved(result.data)
    if (result && result.status === 409 && result.data) return this.refreshStale(result.data)

    this.setBusy(false)
    this.reopenWith(kind, result?.message)
  }

  reopenWith(kind, message) {
    this.failedReply = { kind: kind, message: message || "" }
    this.restoreFailure()
    if (!this.replyMayShowSheet()) return

    this.open()
    if (!this.confirmTarget.disabled) this.confirmTarget.focus()
  }

  get statusKey() {
    return `daily_kind_swap:${this.urlValue}`
  }

  // Read when the queue sends it, so a swap queued behind another posts the version that one's reply left.
  body(kind) {
    return { kind: kind, exercise_id: this.exerciseValue, draft_scope: this.draftScopeValue,
             section_kind_preferences_version: this.panelTarget.dataset.version }
  }

  saved(data) {
    const replaced = this.replacePanels(data.panels)
    this.savedReply = data.want_it_today ? { message: data.message, offer: data.want_it_today, link: data.want_it_today_link } : null
    if (replaced && this.savedReply && this.replyMayShowSheet()) return this.showSavedSheet()

    if (replaced) this.hide(this.replyMayFocus)
    else this.leaveCards()
    this.announce(data.message)
    if (data.set_changed) this.replyTarget.append(this.paragraph(data.set_changed, "daily-kind-note"))
  }

  leaveCards() {
    this.setBusy(false)
    this.hide(this.replyMayFocus)
  }

  refreshStale(data) {
    if (this.replacePanels(data.panels)) return this.settleStale(data.error)

    this.leaveCards()
    this.replyTarget.replaceChildren(this.paragraph(data.set_changed || data.error, "daily-kind-note"))
  }

  settleStale(message) {
    if (this.reconcile()) return this.hide(this.replyMayFocus)

    this.failedReply = { kind: null, message: message || "" }
    this.restoreFailure()
    if (this.replyMayShowSheet()) this.open()
  }

  replacePanels(panels) {
    const mine = this.panelTarget
    const focused = document.activeElement
    const holder = focused?.closest(".daily-kind-swap-panel")?.id
    Object.entries(panels || {}).forEach(([place, html]) => {
      const panel = document.getElementById(`daily-kind-swap-panel-${place}`)
      if (!panel) return
      const reopen = panel !== mine && Boolean(panel.querySelector("dialog")?.open)
      panel.outerHTML = html
      if (reopen) document.getElementById(`daily-kind-swap-panel-${place}`).dataset.sheetOpen = "true"
    })
    if (holder && holder !== mine.id && !focused.isConnected) document.querySelector(`#${holder} .daily-kind-trigger`)?.focus()
    return !mine.isConnected
  }

  showSavedSheet() {
    this.wanted = true
    this.savedMessageTarget.textContent = this.savedReply.message
    this.savedOfferTarget.replaceChildren(this.savedReply.offer, " ", this.regenerateLink(this.savedReply.link))
    this.showSaved(true)
    if (!this.sheetTarget.open) this.sheetTarget.showModal()
    this.doneTarget.focus()
  }

  showSaved(saved) {
    this.choosingTarget.hidden = saved
    this.savedTarget.hidden = !saved
    this.confirmTarget.hidden = saved
    this.cancelTarget.hidden = saved
    this.doneTarget.hidden = !saved
    if (saved) this.consequencesTargets.forEach((element) => { element.hidden = true })
  }

  announce(message) {
    if (!this.savedReply) return this.replyTarget.replaceChildren(this.paragraph(message, "visually-hidden"))

    const offer = this.paragraph(this.savedReply.offer, "daily-kind-note")
    offer.append(" ", this.regenerateLink(this.savedReply.link))
    this.replyTarget.replaceChildren(this.paragraph(this.savedReply.message, "daily-kind-note"), offer)
  }

  paragraph(text, className) {
    const line = document.createElement("p")
    line.className = className
    line.textContent = text
    return line
  }

  regenerateLink(label) {
    const link = document.createElement("a")
    link.href = "#"
    link.textContent = label
    link.addEventListener("click", (event) => this.focusRegenerate(event))
    return link
  }

  focusRegenerate(event) {
    event.preventDefault()
    const button = document.querySelector(".regenerate-row form button")
    this.savedReply = null
    this.hide(!button)
    if (!button) return
    button.scrollIntoView({ block: "center" })
    button.focus()
  }
}
