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
    const retry = !this.pendingSave && this.saveResult?.ok === false &&
      this.saveResult.status !== 409 && !this.saveResult.data?.submitted
    if (this.pendingEdit || retry) this.sendSave()
    const result = await (this.pendingSave ?? this.saveResult ?? { ok: true })
    return { ...result, ok: result.ok || Boolean(result.data?.submitted) }
  }

  // The body is read when the queue sends it, so edits during an in-flight save use the latest text.
  sendSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = null
    this.pendingEdit = false
    const pending = saveStatus.queue("learner_note", "PATCH", this.urlValue,
      () => ({ learner_note: this.inputTarget.value, draft_scope: this.draftScope(), response_id: this.responseIdValue,
        question_key: this.questionKeyValue }), { latest: true }).then((result) => {
      if (this.pendingSave === pending) {
        this.pendingSave = null
        this.saveResult = result
      }
      // Another tab may already have submitted; its refusal must not hold the move to the submitted page.
      if (result.data?.submitted) saveStatus.clear("learner_note")
      if (result.ok && result.data?.question) {
        this.questionTarget.textContent = result.data.question
        this.questionKeyValue = result.data.question_key
      }
      return result
    })
    this.pendingSave = pending
    return pending
  }

  draftScope() {
    return this.element.closest("[data-answer-form-draft-scope-value]")?.dataset.answerFormDraftScopeValue ?? ""
  }
}
