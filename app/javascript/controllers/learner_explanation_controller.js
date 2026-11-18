import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"

export default class extends Controller {
  static targets = ["question", "section", "input", "save", "status", "reply", "replyStatus", "replyFocus"]

  static values = { url: String, draftScope: String, responseId: String, failedText: String, savedText: String, replyUrl: String,
                    askReply: Boolean, waitingText: String, replyFailedText: String, noteId: String, explanationStamp: String }

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
      { section: this.sectionTarget.value, explanation: this.inputTarget.value, draft_scope: this.draftScopeValue, response_id: this.responseIdValue },
      { fallback: this.failedTextValue })
    // The server renders the box's next state, saved or closed; a saved box asks for its reply when it connects.
    if (result.data?.html) {
      this.element.outerHTML = result.data.html
      document.getElementById("learner-explanation-heading")?.focus()
      this.announce(result.ok ? this.savedTextValue : result.message)
      return
    }
    this.saveTarget.disabled = false
    this.statusTarget.textContent = result.message || this.failedTextValue
    this.announce(this.statusTarget.textContent)
  }

  // Only Try again moves focus, so the reply asked for on load leaves it where the reader is.
  async askReply(event) {
    const retry = this.replyTarget.querySelector("button")
    retry?.setAttribute("disabled", "")
    if (this.hasReplyStatusTarget) this.replyStatusTarget.textContent = this.waitingTextValue
    const result = await request.send("POST", this.replyUrlValue,
      { note_id: this.noteIdValue, explanation_stamp: this.explanationStampValue }, { fallback: this.replyFailedTextValue })
    if (result.data?.box) {
      this.replaceBox(result.data.box, result.message, event)
      return
    }
    if (result.data?.html) {
      this.replyTarget.outerHTML = result.data.html
      if (!result.ok && this.hasReplyStatusTarget) this.replyStatusTarget.textContent = result.message
      this.announce(result.ok ? this.replyTarget.textContent : result.message)
      if (event && this.hasReplyFocusTarget) this.replyFocusTarget.focus()
      return
    }
    retry?.removeAttribute("disabled")
    const message = result.message || this.replyFailedTextValue
    if (this.hasReplyStatusTarget) this.replyStatusTarget.textContent = message
    this.announce(message)
  }

  // The explanation this box showed was replaced, so the server sends the whole box as it is now.
  replaceBox(html, message, event) {
    this.element.outerHTML = html
    if (event) document.getElementById("learner-explanation-heading")?.focus()
    this.announce(message)
  }

  announce(text) {
    const announcer = document.getElementById("learner-explanation-announcer")
    if (announcer) announcer.textContent = (text || "").replace(/\s+/g, " ").trim()
  }
}
