// Design notes: docs/code-notes/app/javascript/controllers/exercise_mix_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

const SAVE_DELAY_MS = 400

export default class extends Controller {
  static targets = ["row", "difficulty", "group", "preparation", "prepareButton"]

  static values = {
    url: String,
    stops: Array,
    defaultStop: Number,
    labels: Array,
    version: Number
  }

  connect() {
    this.pending = null
    this.editRevision = 0
    this.probe = () => this.pending !== null
    saveStatus.watch(this.probe)
    this.lockLastInGroup()
    if (this.editedBeforeConnect()) this.adoptEarlyEdit()
  }

  editedBeforeConnect() {
    return Array.from(this.element.querySelectorAll("input")).some((input) =>
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

  chosenLevel(box) {
    return (box.querySelector("input[type=radio]:checked") || { value: "" }).value
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

  state() {
    const weights = {}
    const excluded = []

    this.rowTargets.forEach((row) => {
      const kind = row.dataset.kind
      const value = this.stopsValue[Number(this.sliderFor(row).value)]

      if (this.excludeBoxFor(row).checked) excluded.push(kind)
      if (value !== this.defaultStopValue) weights[kind] = value
    })

    const levels = {}
    const locked = []
    this.difficultyTargets.forEach((box) => {
      const level = this.chosenLevel(box)
      if (level === "") return
      levels[box.dataset.kind] = level
      if (box.querySelector(".mix-lock-box").checked) locked.push(box.dataset.kind)
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

  applyServerState(current) {
    const weights = current.section_kind_weights || {}
    const excluded = current.excluded_section_kinds || []

    this.rowTargets.forEach((row) => {
      const kind = row.dataset.kind
      const slider = this.sliderFor(row)
      const box = this.excludeBoxFor(row)
      const stop = Object.prototype.hasOwnProperty.call(weights, kind) ? weights[kind] : this.defaultStopValue
      const index = this.stopsValue.indexOf(stop)

      slider.value = index === -1 ? this.stopsValue.indexOf(this.defaultStopValue) : index
      this.showStop(slider, row.querySelector("output"))
      box.checked = excluded.indexOf(kind) !== -1
      slider.disabled = box.checked
    })

    const levels = current.section_kind_levels || {}
    const lockedKinds = current.locked_section_kinds || []
    this.difficultyTargets.forEach((box) => {
      const kind = box.dataset.kind
      const level = Object.prototype.hasOwnProperty.call(levels, kind) ? levels[kind] : ""
      box.querySelectorAll("input[type=radio]").forEach((radio) => { radio.checked = radio.value === level })
      box.querySelector(".mix-lock-box").checked = lockedKinds.indexOf(kind) !== -1
      this.setDifficultyDisabled(box, excluded.indexOf(kind) !== -1)
    })

    this.lockLastInGroup()
    this.versionValue = current.section_kind_preferences_version
    this.applyLadderPreparation(current.ladder_preparation)
  }

  persist() {
    let revision
    const payload = () => {
      revision = this.editRevision
      return { user: Object.assign(this.state(), { section_kind_preferences_version: this.versionValue }) }
    }

    // Queued in order: a parallel save would post the version the one in flight is about to move, and 409 against itself.
    return saveStatus.queue("exercise_mix", "PATCH", this.urlValue, payload).then((result) => {
      const reported = result.data && result.data.section_kind_preferences_version
      if (result.ok && typeof reported === "number") this.versionValue = reported
      if (result.status === 409 && result.data && result.data.current) {
        this.applyServerState(result.data.current)
        return revision === this.editRevision
      }

      if (result.ok && revision === this.editRevision) {
        this.applyLadderPreparation(result.data.ladder_preparation)
        return true
      }
      return false
    })
  }

  save() {
    this.editRevision++
    this.prepareButtonTarget.disabled = true
    clearTimeout(this.pending)
    this.pending = setTimeout(() => {
      this.pending = null
      this.persist().then((savedLatest) => {
        this.prepareButtonTarget.disabled = !savedLatest || this.pending !== null || saveStatus.queued("exercise_mix")
      })
    }, SAVE_DELAY_MS)
  }

  slide(event) {
    const row = event.target.closest("[data-exercise-mix-target~='row']")
    this.showStop(event.target, row.querySelector("output"))
    this.save()
  }

  toggleExclude(event) {
    const box = event.target
    const row = box.closest("[data-exercise-mix-target~='row']")
    this.sliderFor(row).disabled = box.checked
    this.lockLastInGroup()
    this.setDifficultyDisabled(this.difficultyFor(row.dataset.kind), box.checked)
    this.save()
  }

  chooseLevel(event) {
    this.syncDifficulty(event.target.closest("[data-exercise-mix-target~='difficulty']"))
    this.save()
  }

  toggleLock() {
    this.save()
  }
}
