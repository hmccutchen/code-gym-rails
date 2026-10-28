// Design notes: docs/code-notes/app/javascript/controllers/daily_sections_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

const KEY = "daily_section_count"

export default class extends Controller {
  static targets = ["count", "choice"]

  static values = {
    url: String,
    layout: Array,
    strandedText: String
  }

  // An edit made before this controller connected fires no event of its own, so adopt it against what the server rendered.
  connect() {
    const picked = this.checkedCount()
    if (picked && !picked.defaultChecked) this.open(picked)
  }

  pick(event) {
    this.open(event.target)
  }

  open(radio) {
    const panel = this.choiceTargets.find((choice) => choice.dataset.count === radio.value)
    this.choiceTargets.forEach((choice) => { choice.hidden = choice !== panel })
    if (panel) return this.showError(panel, "")

    this.send({ daily_section_count: radio.value })
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

  async send(user, options) {
    const result = await saveStatus.queue(KEY, "PATCH", this.urlValue, { user: user, layout: this.layoutValue }, options)
    const moved = result.status === 409 && result.data && result.data.layout_changed
    if (result.ok) this.adopt(result.data)
    if (moved || (result.ok && this.layoutMoved(result.data.daily_kinds))) {
      this.reloadForNewLayout()
      return Object.assign({ reloading: true }, result)
    }
    return result
  }

  adopt(data) {
    const saved = data.daily_section_count === null ? "automatic" : String(data.daily_section_count)
    this.countTargets.forEach((radio) => { radio.defaultChecked = radio.value === saved })
    this.choiceTargets.forEach((choice) => { choice.hidden = true })
  }

  layoutMoved(kinds) {
    return Array.isArray(kinds) && JSON.stringify(kinds) !== JSON.stringify(this.layoutValue)
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
