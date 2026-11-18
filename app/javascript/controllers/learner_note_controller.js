import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

const AUTOSAVE_DELAY_MS = 800

export default class extends Controller {
  static targets = ["question", "input"]

  static values = { url: String, responseId: String, questionKey: String }

  initialize() {
    this.saveTimer = null
    this.pendingEdit = false
    saveStatus.watch(() => this.saveTimer !== null)
  }

  // Text typed before the module loaded fired its input event with no controller to hear it.
  connect() {
    if (this.pendingEdit || this.inputTarget.value !== this.inputTarget.defaultValue) this.save()
  }

  disconnect() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
  }

  save() {
    this.pendingEdit = true
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.sendSave(), AUTOSAVE_DELAY_MS)
  }

  async flush() {
    if (this.saveTimer === null && !this.flushFailed) return { ok: true }
    const result = await this.sendSave()
    this.flushFailed = !result.ok && !result.data?.submitted
    return { ...result, ok: !this.flushFailed }
  }

  // The body is read when the queue sends it, so edits during an in-flight save use the latest text.
  async sendSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    this.pendingEdit = false
    const result = await saveStatus.queue("learner_note", "PATCH", this.urlValue,
      () => ({ learner_note: this.inputTarget.value, draft_scope: this.draftScope(), response_id: this.responseIdValue,
        question_key: this.questionKeyValue }), { latest: true })
    // A submit that landed first leaves the note as stored, so its refusal must not hold the page's move to the review.
    if (result.data?.submitted) {
      saveStatus.clear("learner_note")
      return result
    }
    if (!result.ok || !result.data?.question) return result

    this.flushFailed = false
    this.questionTarget.textContent = result.data.question
    this.questionKeyValue = result.data.question_key
    return result
  }

  draftScope() {
    return this.element.closest("[data-answer-form-draft-scope-value]")?.dataset.answerFormDraftScopeValue ?? ""
  }
}
