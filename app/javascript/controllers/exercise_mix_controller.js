// Design notes: docs/code-notes/app/javascript/controllers/exercise_mix_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"
import trackReply from "code_gym/track_reply"

const SAVE_DELAY_MS = 400
const MIX_FIELDS = ["section_kind_weights", "excluded_section_kinds", "section_kind_levels", "locked_section_kinds"]
const LIST_FIELDS = ["excluded_section_kinds", "locked_section_kinds"]

export default class extends Controller {
  static targets = ["row", "difficulty", "group", "preparation", "prepareButton"]

  static values = {
    url: String,
    layout: Array,
    layoutStrandedText: String,
    stops: Array,
    defaultStop: Number,
    labels: Array,
    version: Number,
    suggested: Object
  }

  connect() {
    this.pending = null
    this.waitingSaves = new Set()
    this.onTheWire = null
    this.touchedSinceTrack = []
    this.savedLatest = true
    this.editRevision = 0
    this.probe = () => this.pending !== null
    saveStatus.watch(this.probe)
    this.lockLastInGroup()
    this.saved = this.state({ rendered: true })
    const early = this.editedBeforeConnect()
    const missedReply = trackReply.take()
    if (missedReply) this.adoptReply(missedReply, early)
    if (early) this.adoptEarlyEdit()
    if (trackReply.saving()) this.prepareButtonTarget.disabled = true
  }

  editedBeforeConnect() {
    const own = "[data-exercise-mix-target~='row'] input, [data-exercise-mix-target~='difficulty'] input"
    return Array.from(this.element.querySelectorAll(own)).some((input) =>
      input.type === "range" ? input.value !== input.defaultValue : input.checked !== input.defaultChecked
    )
  }

  adoptEarlyEdit() {
    this.rowTargets.forEach((row) => {
      const excluded = this.excludeBoxFor(row).checked
      const slider = this.sliderFor(row)
      this.showStop(slider, row.querySelector("output"))
      slider.disabled = excluded
      this.setDifficultyDisabled(this.difficultyFor(row.dataset.kind), excluded)
    })
    this.difficultyTargets.forEach((box) => this.syncDifficulty(box))
    this.lockLastInGroup()
    this.save()
  }

  disconnect() {
    clearTimeout(this.pending)
    this.pending = null
  }

  // Without aria-valuetext a screen reader announces the slider's index, not the stop word.
  showStop(slider, output) {
    const stopLabel = this.labelsValue[Number(slider.value)]
    output.textContent = stopLabel
    slider.setAttribute("aria-valuetext", stopLabel)
  }

  sliderFor(row) {
    return row.querySelector("input[type=range]")
  }

  excludeBoxFor(row) {
    return row.querySelector(".mix-exclude-box")
  }

  difficultyFor(kind) {
    return this.difficultyTargets.find((box) => box.dataset.kind === kind)
  }

  chosenLevel(box, rendered = false) {
    const radios = Array.from(box.querySelectorAll("input[type=radio]"))
    return (radios.find((radio) => (rendered ? radio.defaultChecked : radio.checked)) || { value: "" }).value
  }

  syncDifficulty(box) {
    const targeted = this.chosenLevel(box) !== ""
    const lock = box.querySelector(".mix-lock-box")
    const excluded = box.querySelector("input[type=radio]").disabled

    if (!targeted) lock.checked = false
    lock.disabled = excluded || !targeted
    box.querySelector(".mix-coverage").hidden = !targeted
  }

  setDifficultyDisabled(box, disabled) {
    box.querySelectorAll("input[type=radio]").forEach((radio) => { radio.disabled = disabled })
    this.syncDifficulty(box)
  }

  state({ rendered = false } = {}) {
    const weights = {}
    const excluded = []
    const checked = (input) => (rendered ? input.defaultChecked : input.checked)

    this.rowTargets.forEach((row) => {
      const kind = row.dataset.kind
      const slider = this.sliderFor(row)
      const value = this.stopsValue[Number(rendered ? slider.defaultValue : slider.value)]

      if (checked(this.excludeBoxFor(row))) excluded.push(kind)
      if (value !== this.defaultStopValue) weights[kind] = value
    })

    const levels = {}
    const locked = []
    this.difficultyTargets.forEach((box) => {
      const level = this.chosenLevel(box, rendered)
      if (level === "") return
      levels[box.dataset.kind] = level
      if (checked(box.querySelector(".mix-lock-box"))) locked.push(box.dataset.kind)
    })

    return { section_kind_weights: weights, excluded_section_kinds: excluded,
             section_kind_levels: levels, locked_section_kinds: locked }
  }

  applyLadderPreparation(data) {
    this.preparationTarget.hidden = data.count === 0
    this.prepareButtonTarget.textContent = data.button_label
    this.difficultyTargets.forEach((box) => {
      box.querySelector(".mix-coverage").textContent = data.coverage[box.dataset.kind]
    })
  }

  lockLastInGroup() {
    this.groupTargets.forEach((group) => {
      const boxes = Array.from(group.querySelectorAll(".mix-exclude-box"))
      const remaining = boxes.filter((box) => !box.checked)
      const locked = remaining.length === 1

      remaining.forEach((box) => { box.disabled = locked })
      group.querySelector(".mix-last-note").hidden = !locked
    })
  }

  adoptTrackChange(event) {
    trackReply.take()
    this.adoptReply(event.detail, this.pending !== null || saveStatus.queued("exercise_mix"))
  }

  adoptReply(reply, unsent) {
    const mine = this.state()
    const edits = unsent ? this.withTouched(this.editsSince(this.saved, mine)) : []
    this.touchedSinceTrack = []
    this.forgetMovedSuggestions(reply.kind_rungs)
    this.applyServerState(reply)
    if (edits.length > 0) {
      const adopted = this.saved
      this.applyServerState(this.withEdits(reply, mine, edits))
      this.saved = adopted
    }
    this.savedLatest = true
    this.settlePrepareButton()
  }

  settlePrepareButton() {
    this.prepareButtonTarget.disabled = !this.savedLatest || this.pending !== null || saveStatus.queued("exercise_mix") || trackReply.saving()
  }

  editsSince(before, after) {
    const kinds = this.difficultyTargets.map((box) => box.dataset.kind)
    return MIX_FIELDS.flatMap((field) => kinds
      .filter((kind) => JSON.stringify(this.fieldFor(before, field, kind)) !== JSON.stringify(this.fieldFor(after, field, kind)))
      .map((kind) => ({ field, kind })))
  }

  fieldFor(state, field, kind) {
    if (LIST_FIELDS.indexOf(field) !== -1) return (state[field] || []).indexOf(kind) !== -1
    return (state[field] || {})[kind]
  }

  withEdits(current, mine, edits) {
    const merged = {}
    MIX_FIELDS.forEach((field) => {
      merged[field] = LIST_FIELDS.indexOf(field) !== -1 ? (current[field] || []).slice() : Object.assign({}, current[field])
    })
    edits.forEach(({ field, kind }) => {
      if (LIST_FIELDS.indexOf(field) !== -1) {
        merged[field] = merged[field].filter((listed) => listed !== kind)
        if (this.fieldFor(mine, field, kind)) merged[field].push(kind)
        if (field === "locked_section_kinds" && this.fieldFor(mine, field, kind)) merged.section_kind_levels[kind] = mine.section_kind_levels[kind]
      } else if (Object.prototype.hasOwnProperty.call(mine[field], kind)) {
        merged[field][kind] = mine[field][kind]
      } else {
        delete merged[field][kind]
      }
    })
    merged.locked_section_kinds = merged.locked_section_kinds.filter((kind) => merged.section_kind_levels[kind])
    return Object.assign({}, current, merged)
  }

  applyServerState(current) {
    const excluded = current.excluded_section_kinds || []
    const weights = current.section_kind_weights || {}
    const levels = current.section_kind_levels || {}
    const lockedKinds = current.locked_section_kinds || []

    this.rowTargets.forEach((row) => this.applyRowState(row, weights, excluded))
    this.difficultyTargets.forEach((box) => this.applyDifficultyState(box, levels, lockedKinds, excluded))
    this.lockLastInGroup()
    this.saved = this.state()
    this.versionValue = current.section_kind_preferences_version
    this.applyLadderPreparation(current.ladder_preparation)
  }

  applyRowState(row, weights, excluded) {
    const kind = row.dataset.kind
    const slider = this.sliderFor(row)
    const box = this.excludeBoxFor(row)
    const stop = Object.prototype.hasOwnProperty.call(weights, kind) ? weights[kind] : this.defaultStopValue
    const index = this.stopsValue.indexOf(stop)

    slider.value = index === -1 ? this.stopsValue.indexOf(this.defaultStopValue) : index
    this.showStop(slider, row.querySelector("output"))
    box.checked = excluded.indexOf(kind) !== -1
    slider.disabled = box.checked
  }

  applyDifficultyState(box, levels, lockedKinds, excluded) {
    const kind = box.dataset.kind
    const level = Object.prototype.hasOwnProperty.call(levels, kind) ? levels[kind] : ""

    box.querySelectorAll("input[type=radio]").forEach((radio) => { radio.checked = radio.value === level })
    box.querySelector(".mix-lock-box").checked = lockedKinds.indexOf(kind) !== -1
    this.setDifficultyDisabled(box, excluded.indexOf(kind) !== -1)
  }

  shownSteps(levels) {
    return Object.keys(this.suggestedValue)
      .filter((kind) => levels[kind] === this.suggestedValue[kind].to)
      .map((kind) => Object.assign({ kind }, this.suggestedValue[kind]))
  }

  forgetMovedSuggestions(rungs) {
    if (!rungs || typeof rungs !== "object") return
    const remaining = Object.assign({}, this.suggestedValue)
    Object.keys(remaining).forEach((kind) => {
      if (rungs[kind] !== remaining[kind].from) delete remaining[kind]
    })
    this.suggestedValue = remaining
  }

  persist(snapshot = null) {
    const sent = { revision: undefined, snapshot: snapshot }
    this.waitingSaves.add(sent)
    const payload = () => {
      this.waitingSaves.delete(sent)
      return this.savePayload(sent)
    }

    // Queued in order: a parallel save would post the version the one in flight is about to move, and 409 against itself.
    return saveStatus.queue("exercise_mix", "PATCH", this.urlValue, payload).then((result) => this.reconcile(result, sent))
  }

  savePayload(sent) {
    sent.revision = sent.snapshot ? sent.snapshot.revision : this.editRevision
    const state = sent.snapshot ? this.frozenState(sent.snapshot) : this.state()
    sent.state = JSON.parse(JSON.stringify(state))
    this.onTheWire = sent.state
    const steps = this.shownSteps(state.section_kind_levels)
    const body = { user: Object.assign(state, { section_kind_preferences_version: this.versionValue }), layout: this.layoutValue }
    if (steps.length > 0) body.level_suggestion_steps = steps
    return body
  }

  touch(kind, ...fields) {
    fields.forEach((field) => this.touchedSinceTrack.push({ field, kind }))
  }

  withTouched(edits) {
    const listed = new Set(edits.map(({ field, kind }) => `${field}:${kind}`))
    return edits.concat(this.touchedSinceTrack.filter(({ field, kind }) => !listed.has(`${field}:${kind}`) && listed.add(`${field}:${kind}`)))
  }

  editsFromAnyPending(form) {
    const queued = Array.from(this.waitingSaves).filter((sent) => sent.snapshot).map((sent) => sent.snapshot.state)
    const baselines = [ this.saved, this.onTheWire, ...queued ].filter(Boolean)
    const seen = new Set()
    return baselines.flatMap((baseline) => this.editsSince(baseline, form)).filter(({ field, kind }) => {
      const key = `${field}:${kind}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
  }

  frozenState(snapshot) {
    const merged = this.withEdits(this.saved, snapshot.state, snapshot.edits)
    const state = {}
    MIX_FIELDS.forEach((field) => { state[field] = JSON.parse(JSON.stringify(merged[field])) })
    return state
  }

  reloadForNewLayout() {
    if (this.reloading) return
    this.reloading = true
    saveStatus.reloadWhenSaved("exercise_mix", () => saveStatus.report("exercise_mix", this.layoutStrandedTextValue))
  }

  reconcile(result, sent) {
    const reported = result.data && result.data.section_kind_preferences_version
    if (result.ok && typeof reported === "number") this.versionValue = reported
    if (result.ok) this.forgetMovedSuggestions(result.data && result.data.kind_rungs)
    if (this.onTheWire === sent.state) this.onTheWire = null
    if (result.ok && sent.state) this.saved = sent.state
    if (result.status === 409) this.suggestedValue = {}
    if (result.status === 409 && result.data && result.data.layout_changed) {
      this.reloadForNewLayout()
      return false
    }
    if (result.status === 409 && result.data && result.data.current) {
      this.applyServerState(result.data.current)
      return sent.revision === this.editRevision
    }

    if (result.ok && sent.revision === this.editRevision) {
      this.applyLadderPreparation(result.data.ladder_preparation)
      return true
    }
    return false
  }

  save() {
    this.editRevision++
    this.prepareButtonTarget.disabled = true
    clearTimeout(this.pending)
    this.pending = setTimeout(() => this.sendNow(), SAVE_DELAY_MS)
  }

  holdForTrackSave() {
    this.touchedSinceTrack = []
    this.prepareButtonTarget.disabled = true
    const form = this.state()
    const beforeTrack = { state: form, edits: this.editsFromAnyPending(form), revision: this.editRevision }
    this.waitingSaves.forEach((sent) => { sent.snapshot = sent.snapshot || beforeTrack })
    if (this.pending === null) return
    clearTimeout(this.pending)
    this.sendNow(beforeTrack)
  }

  sendNow(snapshot = null) {
    this.pending = null
    this.persist(snapshot).then((savedLatest) => {
      this.savedLatest = savedLatest
      this.settlePrepareButton()
    })
  }

  slide(event) {
    const row = event.target.closest("[data-exercise-mix-target~='row']")
    this.showStop(event.target, row.querySelector("output"))
    this.touch(row.dataset.kind, "section_kind_weights")
    this.save()
  }

  toggleExclude(event) {
    const box = event.target
    const row = box.closest("[data-exercise-mix-target~='row']")
    this.sliderFor(row).disabled = box.checked
    this.lockLastInGroup()
    this.setDifficultyDisabled(this.difficultyFor(row.dataset.kind), box.checked)
    this.touch(row.dataset.kind, "excluded_section_kinds")
    this.save()
  }

  chooseLevel(event) {
    const box = event.target.closest("[data-exercise-mix-target~='difficulty']")
    this.syncDifficulty(box)
    this.touch(box.dataset.kind, "section_kind_levels", "locked_section_kinds")
    this.save()
  }

  toggleLock(event) {
    this.touch(event.target.closest("[data-exercise-mix-target~='difficulty']").dataset.kind, "locked_section_kinds")
    this.save()
  }
}
