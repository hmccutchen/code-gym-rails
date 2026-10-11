// Design notes: docs/code-notes/app/javascript/controllers/display_preferences_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static values = {
    url: String,
    defaults: Object,
    palette: Object,
    paletteOff: String
  }

  chosen() {
    const values = {}
    this.element.querySelectorAll("input[type=radio]:checked").forEach((radio) => {
      values[radio.dataset.setting] = radio.value
    })
    return values
  }

  // Mirrors the attributes the layout renders from stored values; change both together.
  apply(values) {
    const root = document.documentElement
    Object.entries(values).forEach(([setting, value]) => {
      const attribute = "data-" + setting.replace(/_/g, "-")
      if (value === this.defaultsValue[setting]) root.removeAttribute(attribute)
      else root.setAttribute(attribute, value)
    })

    const media = this.paletteValue[values.theme] || this.paletteOffValue
    document.querySelectorAll("[data-light-palette-media]").forEach((element) => { element.media = media })
    this.applyPattern(values.background_pattern)
  }

  applyPattern(setting) {
    const pattern = document.getElementById("background-pattern")
    if (setting === "off") {
      pattern?.remove()
      return
    }
    if (pattern) return

    const layer = document.createElement("div")
    layer.id = "background-pattern"
    layer.setAttribute("aria-hidden", "true")
    document.body.prepend(layer)
  }

  // Queued in order: each save carries the whole object, so parallel saves could land out of order.
  change() {
    this.apply(this.chosen())
    saveStatus.queue("display_preferences", "PATCH", this.urlValue,
                     () => ({ user: { display_preferences: this.chosen() } }))
  }
}
