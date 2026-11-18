import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["question", "input"]

  static values = { url: String, responseId: String, questionKey: String }

  // The body is read when the save is sent, so a burst of typing collapses into the latest text.
  async save() {
    const result = await saveStatus.queue("learner_note", "PATCH", this.urlValue,
      () => ({ learner_note: this.inputTarget.value, draft_scope: this.draftScope(), response_id: this.responseIdValue,
        question_key: this.questionKeyValue }), { latest: true })
    // A submit that landed first leaves the note as stored, so its refusal must not hold the page's move to the review.
    if (result.data?.submitted) return saveStatus.clear("learner_note")
    if (!result.ok || !result.data?.question) return

    this.questionTarget.textContent = result.data.question
    this.questionKeyValue = result.data.question_key
  }

  draftScope() {
    return this.element.closest("[data-answer-form-draft-scope-value]")?.dataset.answerFormDraftScopeValue ?? ""
  }
}
