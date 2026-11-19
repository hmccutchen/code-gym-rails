import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["question", "section", "input", "save", "status", "reply", "replyStatus", "replyFocus", "replyPending"]

  static values = { url: String, draftScope: String, responseId: String, failedText: String, savedText: String, replyUrl: String,
                    askReply: Boolean, waitingText: String, replyFailedText: String, noteId: String, explanationStamp: String,
                    replyStatusUrl: String, pollSeconds: Number }

  initialize() {
    saveStatus.watchUnsent(() => this.element.isConnected && this.hasInputTarget && this.inputTarget.value.trim() !== this.inputTarget.defaultValue.trim())
  }

  connect() {
    if (this.askReplyValue) this.askReply()
    else this.pollWhilePending()
  }

  disconnect() {
    clearTimeout(this.pollTimer)
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
    const result = await request.send("POST", this.replyUrlValue, this.shownExplanation(), { fallback: this.replyFailedTextValue })
    if (result.data?.box) {
      this.replaceBox(result.data.box, result.message, event)
      return
    }
    if (result.data?.html) {
      this.replyTarget.outerHTML = result.data.html
      if (!result.ok && this.hasReplyStatusTarget) this.replyStatusTarget.textContent = result.message
      this.announce(result.ok ? this.replyTarget.textContent : result.message)
      if (event && this.hasReplyFocusTarget) this.replyFocusTarget.focus()
      this.pollWhilePending()
      return
    }
    this.offerRetry(retry)
    this.showReplyMessage(result.message || this.replyFailedTextValue)
  }

  showReplyMessage(message) {
    if (this.hasReplyStatusTarget) this.replyStatusTarget.textContent = message
    this.announce(message)
  }

  shownExplanation() {
    return { note_id: this.noteIdValue, explanation_stamp: this.explanationStampValue, draft_scope: this.draftScopeValue }
  }

  offerRetry(retry) {
    if (!retry) return
    retry.removeAttribute("disabled")
    retry.hidden = false
  }

  // Another request holds the claim, so the box reads its state, doubling the wait, until it settles or the claim would go stale.
  pollWhilePending(delay = 1000, waited = 0) {
    clearTimeout(this.pollTimer)
    if (!this.hasReplyPendingTarget) return
    if (waited >= this.pollSecondsValue * 1000) return this.offerRetry(this.replyTarget.querySelector("button"))

    this.pollTimer = setTimeout(() => this.readReplyStatus(delay, waited + delay), delay)
  }

  async readReplyStatus(delay, waited) {
    const query = new URLSearchParams(this.shownExplanation())
    const result = await request.get(`${this.replyStatusUrlValue}?${query}`)
    if (!this.element.isConnected) return
    if (result.data?.box) return this.replaceBox(result.data.box, result.message)
    if (result.ok && result.data?.html) {
      this.replyTarget.outerHTML = result.data.html
      if (!this.hasReplyPendingTarget) this.announce(this.replyTarget.textContent)
    } else if (result.status !== 0) {
      this.offerRetry(this.replyTarget.querySelector("button"))
      return this.showReplyMessage(result.message)
    }
    this.pollWhilePending(Math.min(delay * 2, 30000), waited)
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
