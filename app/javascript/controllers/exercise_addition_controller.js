import { Controller } from "@hotwired/stimulus"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

export default class extends Controller {
  static targets = ["trigger", "sheet", "option", "confirm", "status", "error"]
  static values = { url: String, pending: Boolean, working: String, failed: String, added: String, unreachable: String }

  connect() {
    this.stopped = false
    this.ticket = 0
    this.refresh = () => this.poll()
    this.submission = () => this.controls()
    this.formElement = this.element.closest('[data-controller~="answer-form"]')
    this.formElement.addEventListener("answer-form:structure-needed", this.refresh)
    this.formElement.addEventListener("answer-form:submission-state", this.submission)
    this.schedule(0)
  }

  disconnect() {
    this.stopped = true
    clearTimeout(this.timer)
    this.formElement.removeEventListener("answer-form:structure-needed", this.refresh)
    this.formElement.removeEventListener("answer-form:submission-state", this.submission)
  }

  get form() {
    return this.application.getControllerForElementAndIdentifier(this.formElement, "answer-form")
  }

  present() {
    if (document.visibilityState === "visible") this.poll()
  }

  schedule(delay = 2000) {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.poll(), delay)
  }

  async poll() {
    if (this.stopped || this.posting) return
    if (!this.form) return this.schedule(100)
    this.form.additionState(this.pendingValue)
    const ticket = ++this.ticket
    const query = new URLSearchParams({ draft_scope: this.form.draftScopeValue, revision: this.form.manifestRevisionValue })
    const result = await request.get(`${this.urlValue}?${query}`, { fallback: this.unreachableValue })
    if (this.stopped || ticket !== this.ticket) return
    if (result.ok) this.accept(result.data)
    else this.statusTarget.textContent = result.message
    if (this.pendingValue && !result.signedOut && ![404, 409].includes(result.status)) this.schedule()
  }

  accept(data) {
    if (!this.form || data.draft_scope !== this.form.draftScopeValue || data.manifest_revision < this.form.manifestRevisionValue) return
    if (data.submitted) {
      this.pendingValue = false
      this.triggerTarget.hidden = true
      this.triggerTarget.disabled = true
      this.close(false)
      return
    }
    if (!this.form.reconcileStructure(data)) return
    const operation = data.operation
    if (operation?.request_uuid === this.attempt?.request_uuid) this.attempt = null
    this.pendingValue = Boolean(operation && ["queued", "running"].includes(operation.status) && !operation.expired)
    this.form.additionState(this.pendingValue)
    this.optionTargets.forEach((option) => {
      option.hidden = !data.available_kinds.includes(option.dataset.kind)
      if (option.hidden) option.querySelector("input").checked = false
    })
    this.triggerTarget.hidden = data.available_kinds.length === 0
    const name = this.optionTargets.find((option) => option.dataset.kind === operation?.kind)?.dataset.name || ""
    this.statusTarget.textContent = this.pendingValue ? this.workingValue.replace("%{kind}", name)
      : operation?.expired || operation?.status === "failed" ? this.failedValue
      : operation?.status === "succeeded" ? this.addedValue : ""
    this.controls()
  }

  open() {
    if (this.posting || this.pendingValue || this.form?.formTarget.inert) return
    this.sheetTarget.showModal()
    this.errorTarget.textContent = ""
    this.optionTargets.find((option) => !option.hidden)?.querySelector("input").focus()
  }

  close(focus = true) {
    if (this.sheetTarget.open) this.sheetTarget.close()
    if (focus && !this.triggerTarget.disabled) this.triggerTarget.focus()
  }

  escape(event) {
    event.preventDefault()
    this.close()
  }

  press(event) { this.pressedBackdrop = event.target === this.sheetTarget }

  backdrop(event) {
    if (this.pressedBackdrop && event.target === this.sheetTarget) this.close()
    this.pressedBackdrop = false
  }

  selected() {
    return this.optionTargets.find((option) => !option.hidden && option.querySelector("input").checked)?.dataset.kind
  }

  choose() {
    if (this.attempt && this.selected() !== this.attempt.kind) {
      this.optionTargets.forEach((option) => { option.querySelector("input").checked = option.dataset.kind === this.attempt.kind })
    }
    this.confirmTarget.disabled = this.posting || this.pendingValue || this.form?.formTarget.inert || !this.selected()
  }

  controls() {
    this.triggerTarget.disabled = this.posting || this.pendingValue || Boolean(this.form?.formTarget.inert)
    this.choose()
  }

  async confirm() {
    const kind = this.selected()
    if (!kind || this.posting || this.pendingValue || this.form?.formTarget.inert) return
    this.posting = true
    this.errorTarget.textContent = ""
    ++this.ticket
    this.choose()
    this.form.additionState(true)
    this.attempt ||= { request_uuid: crypto.randomUUID(), kind: kind }
    const result = await saveStatus.queue("exercise_addition", "POST", this.urlValue, {
      ...this.attempt, draft_scope: this.form.draftScopeValue, revision: this.form.manifestRevisionValue
    })
    if (this.stopped) return
    this.posting = false
    if (!result.unreached) this.attempt = null
    if (result.data?.draft_scope) this.accept(result.data)
    else this.form.additionState(false)
    if (result.ok) {
      saveStatus.clear("exercise_addition")
      this.close(false)
    } else {
      this.statusTarget.textContent = result.message || this.unreachableValue
      this.errorTarget.textContent = this.statusTarget.textContent
    }
    this.choose()
    this.poll()
  }
}
