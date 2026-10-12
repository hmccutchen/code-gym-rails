// Design notes: docs/code-notes/app/javascript/controllers/pull_to_refresh_controller.md
import { Controller } from "@hotwired/stimulus"
import saveStatus from "code_gym/save_status"

// UIScrollView's rubber band: travel approaches MAX_TRAVEL but never reaches it.
const MAX_TRAVEL = 160
const THRESHOLD = 64
const HOLD = 64
const MIN_SPIN_MS = 500
const SAVE_POLL_MS = 100
const SAVE_WAIT_LIMIT_MS = 10000
const RELOADED_KEY = "codegym:pull-refreshed"
const HOLDING_CLASS = "pull-resuming"

function isEditable(element) {
  return element instanceof Element && element.matches("input, textarea, select, [contenteditable]")
}

function insideScrolledArea(element) {
  for (let node = element; node instanceof Element; node = node.parentElement) {
    if (node.scrollTop > 0) return true
  }
  return false
}

// sessionStorage throws in some private modes; the spinner is only polish.
function remember(key, value) {
  try { sessionStorage.setItem(key, value) } catch {}
}

export default class extends Controller {
  static values = { settleDelay: { type: Number, default: 400 } }

  connect() {
    this.content = document.querySelector("[data-pull-content]")
    const resuming = document.documentElement.classList.contains(HOLDING_CLASS)
    document.documentElement.classList.remove(HOLDING_CLASS)
    if (!this.content || getComputedStyle(this.element).display === "none") return

    this.nav = document.querySelector("body > nav")
    this.spinner = this.element.querySelector(".spinner")
    this.startY = null
    this.ready = false
    this.refreshing = false
    this.gap = null
    this.listening = true

    this.onTouchStart = (event) => this.touchStart(event)
    this.onTouchMove = (event) => this.touchMove(event)
    this.onTouchEnd = () => this.touchEnd()
    this.onTouchCancel = () => { if (this.startY !== null) this.reset() }

    document.addEventListener("touchstart", this.onTouchStart, { passive: true })
    document.addEventListener("touchmove", this.onTouchMove, { passive: true })
    document.addEventListener("touchend", this.onTouchEnd)
    document.addEventListener("touchcancel", this.onTouchCancel)

    if (resuming) this.resumeAfterReload()
  }

  disconnect() {
    if (!this.listening) return
    this.listening = false
    clearTimeout(this.reloadTimer)
    clearTimeout(this.settleTimer)
    document.removeEventListener("touchstart", this.onTouchStart)
    document.removeEventListener("touchmove", this.onTouchMove)
    document.removeEventListener("touchend", this.onTouchEnd)
    document.removeEventListener("touchcancel", this.onTouchCancel)
  }

  canStart(event) {
    return event.touches.length === 1 &&
           window.scrollY <= 0 &&
           !isEditable(document.activeElement) &&
           !isEditable(event.target) &&
           !document.querySelector("form[inert]") &&
           !insideScrolledArea(event.target)
  }

  // Read while the content is at rest, so the gap is the layout's own.
  measureGap() {
    const top = this.nav ? this.nav.getBoundingClientRect().bottom : 0
    this.gap = { top, height: this.content.getBoundingClientRect().top - top }
  }

  moveTo(travel) {
    const middle = this.gap.top + (this.gap.height + travel) / 2
    this.content.style.transform = travel > 0 ? `translateY(${travel}px)` : ""
    this.element.style.transform = `translateY(${middle - this.element.offsetHeight / 2}px)`
  }

  setSettling(settling) {
    this.element.classList.toggle("is-settling", settling)
    this.content.classList.toggle("pull-settling", settling)
  }

  show(distance) {
    const travel = distance * MAX_TRAVEL / (distance + MAX_TRAVEL)
    this.setSettling(false)
    this.moveTo(travel)
    this.element.style.opacity = Math.min(travel / THRESHOLD, 1)
    this.spinner.style.transform = `rotate(${travel * 4}deg)`
    this.ready = travel >= THRESHOLD
    this.element.classList.toggle("is-ready", this.ready)
  }

  spin() {
    this.refreshing = true
    this.spinner.style.transform = ""
    this.element.classList.add("is-refreshing")
    this.moveTo(HOLD)
    this.element.style.opacity = 1
  }

  reset() {
    this.startY = null
    this.ready = false
    this.refreshing = false
    this.setSettling(true)
    this.element.classList.remove("is-refreshing", "is-ready")
    this.content.style.transform = ""
    this.element.style.transform = ""
    this.element.style.opacity = ""
  }

  reload() {
    remember(RELOADED_KEY, "1")
    window.location.reload()
  }

  reloadWhenSaved(waited = 0) {
    if (!this.listening) return
    if (!saveStatus.pending()) return this.reload()
    if (waited >= SAVE_WAIT_LIMIT_MS) return this.reset()
    this.reloadTimer = setTimeout(() => this.reloadWhenSaved(waited + SAVE_POLL_MS), SAVE_POLL_MS)
  }

  // A second finger, or a touch that cannot start a pull, ends the pull already showing.
  touchStart(event) {
    if (this.refreshing) return
    if (this.startY !== null) this.reset()
    if (!this.canStart(event)) return
    this.measureGap()
    this.startY = event.touches[0].clientY
  }

  touchMove(event) {
    if (this.startY === null) return
    const distance = event.touches[0].clientY - this.startY
    if (distance <= 0 || window.scrollY > 0) return this.reset()
    this.show(distance)
  }

  touchEnd() {
    if (this.startY === null) return
    if (!this.ready) return this.reset()

    this.startY = null
    this.setSettling(true)
    this.spin()
    this.reloadTimer = setTimeout(() => this.reloadWhenSaved(), MIN_SPIN_MS)
  }

  resumeAfterReload() {
    this.measureGap()
    this.moveTo(HOLD)
    this.element.getBoundingClientRect()
    this.setSettling(true)
    this.spin()
    const settle = () => { this.settleTimer = setTimeout(() => this.reset(), this.settleDelayValue) }
    if (document.readyState === "complete") settle()
    else window.addEventListener("load", settle, { once: true })
  }
}
