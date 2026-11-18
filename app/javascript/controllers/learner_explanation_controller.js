import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["question", "section", "input", "save", "status", "reply", "replyStatus"]

  static values = { url: String, draftScope: String, responseId: String, failedText: String, replyUrl: String, askReply: Boolean, waitingText: String, replyFailedText: String }

  connect() {
    if (this.askReplyValue) this.askReply()
  }

  choose() {
    this.questionTarget.textContent = this.sectionTarget.selectedOptions[0].dataset.question
  }

  async save() {
    this.saveTarget.disabled = true
    this.statusTarget.textContent = ""
    const result = await request.send("POST", this.urlValue,
      { section: this.sectionTarget.value, explanation: this.inputTarget.value, draft_scope: this.draftScopeValue, response_id: this.responseIdValue }, { fallback: this.failedTextValue })
    // The server renders the box's next state, saved or closed; a saved box asks for its reply when it connects.
    if (result.data?.html) {
      this.element.outerHTML = result.data.html
      return
    }
    this.saveTarget.disabled = false
    this.statusTarget.textContent = result.message || this.failedTextValue
  }

  async askReply() {
    this.replyTarget.querySelector("button")?.setAttribute("disabled", "")
    if (this.hasReplyStatusTarget) this.replyStatusTarget.textContent = this.waitingTextValue
    const result = await request.send("POST", this.replyUrlValue, {}, { fallback: this.replyFailedTextValue })
    if (result.data?.html) {
      this.replyTarget.outerHTML = result.data.html
      return
    }
    if (this.hasReplyStatusTarget) this.replyStatusTarget.textContent = result.message || this.replyFailedTextValue
  }
}
