// Design notes: docs/code-notes/app/javascript/controllers/time_zone_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static values = { url: String }

  connect() {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone
    if (!zone) return

    saveStatus.queue("time_zone", "PATCH", this.urlValue, { user: { time_zone: zone } }, { quiet: true })
  }
}
