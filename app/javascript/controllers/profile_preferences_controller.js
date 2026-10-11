// Design notes: docs/code-notes/app/javascript/controllers/profile_preferences_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["timeZone", "dailySections", "skillLevel"]

  static values = {
    url: String,
    labelTemplate: String
  }

  // Key per control: all controls PATCH one path, and a shared key lets one success clear another's warning.
  queueSave(key, payload) {
    return saveStatus.queue(key, "PATCH", this.urlValue, { user: payload })
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
    const result = await this.queueSave("skill_level", { skill_level: level })
    if (!result.ok) return

    const levelLabel = Array.from(select.options).find((option) => option.value === level).textContent
    document.querySelectorAll("[data-skill-level-label]").forEach((label) => {
      label.textContent = this.labelTemplateValue.replace("__LEVEL__", levelLabel)
    })
  }
}
