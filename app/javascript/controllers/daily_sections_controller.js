// Design notes: docs/code-notes/app/javascript/controllers/daily_sections_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

const KEY = "daily_section_count"

export default class extends Controller {
  static targets = ["count", "choice"]

  static values = {
    url: String,
    layout: Array,
    rotates: Boolean,
    places: Array,
    strandedText: String
  }

  // An edit made before this controller connected fires no event of its own, so adopt it against what the server rendered.
  connect() {
    this.unsent = 0
    this.latest = null
    const picked = this.checkedCount()
    if (picked && !picked.defaultChecked) this.open(picked)
  }

  pick(event) {
    this.open(event.target)
  }

  // A tap on the saved count fires no change event, so this is the only way back into its chooser.
  reopen(event) {
    if (event.target.defaultChecked) this.showChoice(event.target)
  }

  open(radio) {
    if (!this.showChoice(radio)) this.send({ daily_section_count: radio.value })
  }

  showChoice(radio) {
    const panel = this.choiceTargets.find((choice) => choice.dataset.count === radio.value)
    this.choiceTargets.forEach((choice) => { choice.hidden = choice !== panel })
    if (panel) this.showError(panel, "")
    return Boolean(panel)
  }

  async save(event) {
    const panel = event.target.closest("[data-daily-sections-target~=choice]")
    const button = event.target
    const label = button.textContent
    button.disabled = true
    button.textContent = button.dataset.savingText
    try {
      const result = await this.send({ daily_section_count: Number(panel.dataset.count), daily_section_kinds: this.kindsFrom(panel) },
                                      { quiet: true })
      if (!result.ok && !result.reloading) this.showError(panel, result.message)
    } finally {
      button.disabled = false
      button.textContent = label
    }
  }

  cancel() {
    this.choiceTargets.forEach((choice) => { choice.hidden = true })
    const saved = this.countTargets.find((radio) => radio.defaultChecked)
    if (!saved) return
    saved.checked = true
    saved.focus()
  }

  kindsFrom(panel) {
    const kept = panel.querySelector("input[type=radio]:checked")
    if (kept) return JSON.parse(kept.value)

    const extras = Array.from(panel.querySelectorAll("select[data-daily-sections-extra]"), (select) => select.value)
    return JSON.parse(panel.dataset.pair).concat(extras)
  }

  // An Exercise mix edit still waiting to send would post the old layout after this one and lose itself to the reload.
  async send(user, options) {
    this.unsent += 1
    let result
    try {
      await saveStatus.settled(KEY)
      const body = { user: user, layout: this.layoutValue, places: this.placesValue }
      result = await saveStatus.queue(KEY, "PATCH", this.urlValue, body, options)
    } finally {
      this.unsent -= 1
    }
    const moved = result.status === 409 && result.data && result.data.layout_changed
    if (result.ok) this.adopt(result.data)
    if (moved || (this.unsent === 0 && this.latest && this.layoutMoved(this.latest))) {
      this.reloadForNewLayout()
      return Object.assign({ reloading: true }, result)
    }
    return result
  }

  adopt(data) {
    this.latest = data
    const saved = data.daily_section_count === null ? "automatic" : String(data.daily_section_count)
    this.countTargets.forEach((radio) => { radio.defaultChecked = radio.value === saved })
    this.choiceTargets.forEach((choice) => { choice.hidden = true })
  }

  layoutMoved(data) {
    const kinds = data.daily_kinds
    return (Array.isArray(kinds) && JSON.stringify(kinds) !== JSON.stringify(this.layoutValue)) || data.rotates !== this.rotatesValue
  }

  // The Exercise mix below is rendered for the old daily kinds, so the page reloads once every other save lands.
  reloadForNewLayout() {
    saveStatus.reloadWhenSaved(KEY, () => saveStatus.report(KEY, this.strandedTextValue))
  }

  checkedCount() {
    return this.countTargets.find((radio) => radio.checked)
  }

  showError(panel, message) {
    panel.querySelector("[data-daily-sections-error]").textContent = message || ""
  }
}
