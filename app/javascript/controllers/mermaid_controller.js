// Design notes: docs/code-notes/app/javascript/controllers/mermaid_controller.md
import { Controller } from "@hotwired/stimulus"

const MERMAID_URL = "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.esm.min.mjs"

export default class extends Controller {
  async connect() {
    if (this.pending.length === 0) return

    try {
      const mermaid = (await import(MERMAID_URL)).default
      // securityLevel stays strict: the diagram source is model-generated.
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict" })
      await this.renderAll(mermaid)
    } catch {
      this.pending.forEach((element) => this.removeFailed(element))
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
