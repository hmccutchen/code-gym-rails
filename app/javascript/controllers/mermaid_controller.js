// Design notes: docs/code-notes/app/javascript/controllers/mermaid_controller.md
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() { this.renderPending() }

  async renderPending() {
    if (this.rendering || this.pending.length === 0) return
    this.rendering = true

    try {
      const mermaid = (await import("mermaid")).default
      // securityLevel stays strict: the diagram source is model-generated.
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict" })
      do {
        await this.renderAll(mermaid)
      } while (this.pending.length > 0)
    } catch {
      this.pending.forEach((element) => this.removeFailed(element))
    } finally {
      this.rendering = false
    }
  }

  async renderAll(mermaid) {
    for (const element of this.pending) {
      element.dataset.mermaidDone = "1"
      const source = element.dataset.diagram
      try {
        await mermaid.parse(source)
        const { svg } = await mermaid.render("mmd-" + Math.random().toString(36).slice(2), source)
        element.innerHTML = svg
      } catch {
        this.removeFailed(element)
      }
    }
  }

  // Remove the <details> only when the partial created it; architecture's belongs to its caller.
  removeFailed(element) {
    (element.dataset.ownsDetails === "1" ? element.closest("details") : element).remove()
  }

  get pending() {
    return [ ...this.element.querySelectorAll(".mermaid-diagram[data-diagram]:not([data-mermaid-done])") ]
  }
}
