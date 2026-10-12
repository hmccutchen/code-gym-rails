// Design notes: docs/code-notes/app/javascript/controllers/parsons_controller.md
import { Controller } from "@hotwired/stimulus"

const SORTABLE_URL = "https://cdn.jsdelivr.net/npm/sortablejs@1.15.6/modular/sortable.esm.js"
const DRAG_FALLBACK_MS = 3000

export default class extends Controller {
  static targets = ["list", "block", "status", "field"]

  static values = {
    prefix: String,
    movedText: String,
    recordedText: String,
    moveUpText: String,
    moveDownText: String
  }

  connect() {
    this.listTarget.dataset.parsonsWired = "1"
    // A hung CDN never rejects the import below, so its catch alone would leave this unanswerable.
    this.fallbackTimer = setTimeout(() => this.addControls(), DRAG_FALLBACK_MS)
    this.loadSortable()
  }

  disconnect() {
    clearTimeout(this.fallbackTimer)
    this.sortable?.destroy()
  }

  async loadSortable() {
    try {
      const { default: Sortable } = await import(SORTABLE_URL)
      if (!this.element.isConnected) return
      // delayOnTouchOnly: a touch drag needs a brief hold so an ordinary swipe still scrolls the page.
      this.sortable = Sortable.create(this.listTarget, {
        animation: matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 150,
        delay: 150,
        delayOnTouchOnly: true,
        onEnd: () => this.syncField()
      })
      clearTimeout(this.fallbackTimer)
      this.listTarget.dataset.sortableDone = "1"
    } catch {
      this.addControls()
    }
  }

  confirm() {
    this.syncField()
    this.statusTarget.textContent = this.recordedTextValue
  }

  keydown(event) {
    const block = event.target.closest?.(".parsons-block")
    if (!block || !this.listTarget.contains(block)) return
    const direction = event.key === "ArrowUp" ? "up" : event.key === "ArrowDown" ? "down" : null
    if (!direction) return

    if (event.ctrlKey || event.metaKey) {
      event.preventDefault()
      this.move(block, direction)
      block.focus()
      return
    }
    const sibling = direction === "up" ? block.previousElementSibling : block.nextElementSibling
    if (sibling) {
      event.preventDefault()
      sibling.focus()
    }
  }

  move(block, direction) {
    if (direction === "up") {
      const previous = block.previousElementSibling
      if (!previous) return
      this.listTarget.insertBefore(block, previous)
    } else {
      const next = block.nextElementSibling
      if (!next) return
      this.listTarget.insertBefore(next, block)
    }
    this.syncField()
    this.announce(block)
  }

  syncField() {
    const ids = this.blockTargets.map((block) => block.dataset.blockId)
    this.fieldTarget.value = this.prefixValue + ids.join(",")
    this.fieldTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.fieldTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  announce(block) {
    const blocks = this.blockTargets
    this.statusTarget.textContent = this.movedTextValue
      .replace("%{position}", blocks.indexOf(block) + 1)
      .replace("%{total}", blocks.length)
  }

  addControls() {
    if (this.listTarget.dataset.parsonsControls) return
    this.listTarget.dataset.parsonsControls = "1"
    this.blockTargets.forEach((block) => {
      const controls = document.createElement("div")
      controls.className = "parsons-controls"
      controls.append(this.controlButton(block, "up"), this.controlButton(block, "down"))
      block.appendChild(controls)
    })
  }

  controlButton(block, direction) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = `btn btn-ghost btn-sm parsons-move-${direction}`
    button.textContent = direction === "up" ? "↑" : "↓"
    button.setAttribute("aria-label", direction === "up" ? this.moveUpTextValue : this.moveDownTextValue)
    button.addEventListener("click", () => this.move(block, direction))
    return button
  }
}
