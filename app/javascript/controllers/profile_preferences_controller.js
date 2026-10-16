// Design notes: docs/code-notes/app/javascript/controllers/profile_preferences_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"
import trackReply from "code_gym/track_reply"

export default class extends Controller {
  static targets = ["timeZone", "dailySections", "skillLevel", "keptOwnLevel"]

  static values = {
    url: String,
    labelTemplate: String
  }

  // An edit made before this controller connected fires no event of its own, so adopt it against what the server rendered.
  connect() {
    if (this.timeZoneTarget.value !== this.renderedValue(this.timeZoneTarget)) this.saveTimeZone()

    const sections = this.dailySectionsTarget.querySelector("input[type=radio]:checked")
    if (sections && !sections.defaultChecked) {
      this.queueSave("daily_section_count", { daily_section_count: sections.value })
    }

    if (this.skillLevelTarget.value !== this.renderedValue(this.skillLevelTarget)) this.saveSkillLevel()
  }

  renderedValue(select) {
    return Array.from(select.options).find((option) => option.defaultSelected)?.value
  }

  // Key per control: all controls PATCH one path, and a shared key lets one success clear another's warning.
  queueSave(key, payload, options) {
    return saveStatus.queue(key, "PATCH", this.urlValue, { user: payload }, options)
  }

  saveTimeZone() {
    this.queueSave("time_zone", { time_zone: this.timeZoneTarget.value })
  }

  saveDailySections(event) {
    this.queueSave("daily_section_count", { daily_section_count: event.target.value })
  }

  async saveSkillLevel() {
    const select = this.skillLevelTarget
    const level = select.value
    this.dispatch("trackSaving", { target: document })
    const result = await this.queueSave("skill_level", { skill_level: level }, { line: "exercise_mix" })
    if (!result.ok) return this.dispatch("trackFailed", { target: document })

    // A track change can clear targets; the Exercise mix adopts the saved state rather than keep its own copy.
    const reply = Object.assign({ kind_rungs: result.data.kind_rungs }, result.data.preferences)
    trackReply.record(reply)
    this.dispatch("trackSaved", { target: document, detail: reply })
    this.keptOwnLevelTarget.textContent = result.data.kept_own_level

    const levelLabel = Array.from(select.options).find((option) => option.value === level).textContent
    document.querySelectorAll("[data-skill-level-label]").forEach((label) => {
      label.textContent = this.labelTemplateValue.replace("__LEVEL__", levelLabel)
    })
  }
}
