// Design notes: docs/code-notes/app/javascript/controllers/code_lines_controller.md
import { Controller } from "@hotwired/stimulus"

const WRAP_RATIO = 1.5

export default class extends Controller {
  connect() {
    // Fitting changes a block's height, never its width, so reacting to width alone cannot loop.
    this.widths = new WeakMap()
    this.observer = new ResizeObserver((entries) => {
      entries.forEach(({ target, contentRect }) => {
        if (this.widths.get(target) === contentRect.width) return

        this.widths.set(target, contentRect.width)
        this.fit(target.querySelector(":scope > code"))
      })
    })

    for (const code of this.element.querySelectorAll("code.highlight")) {
      // Observes the <pre>, since an inline <code> reports no size.
      if (code.querySelector(".code-align-extra")) this.observer.observe(code.parentElement)
    }
  }

  disconnect() {
    this.observer?.disconnect()
  }

  fit(code) {
    code.removeAttribute("data-wraps")

    const probe = document.createElement("span")
    probe.className = "code-line"
    probe.textContent = "x"
    code.append(probe)
    const row = probe.getBoundingClientRect().height
    probe.remove()
    // A hidden block (a closed disclosure) measures zero; the observer fits it when it opens.
    if (row === 0) return

    const wraps = [...code.children].some((line) => line.getBoundingClientRect().height > row * WRAP_RATIO)
    code.toggleAttribute("data-wraps", wraps)
  }
}
