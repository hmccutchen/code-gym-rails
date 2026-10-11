// Design notes: docs/code-notes/app/javascript/controllers/push_enable_controller.md
import { Controller } from "@hotwired/stimulus"
import push from "code_gym/push"

export default class extends Controller {
  static targets = ["button", "status"]

  static values = {
    vapidKey: String,
    registerPath: String,
    knownEndpoints: Array,
    registerFailedText: String,
    homeScreenOnlyText: String,
    unsupportedText: String,
    waitingText: String,
    blockedText: String,
    notGrantedText: String,
    failedText: String
  }

  connect() {
    if (push.supported()) return

    this.buttonTarget.disabled = true
    this.say(this.isApplePortable ? this.homeScreenOnlyTextValue : this.unsupportedTextValue)
  }

  enable() {
    // Must stay the first statement: iOS silently refuses a permission request not made synchronously in the gesture.
    const permission = Notification.requestPermission()

    this.buttonTarget.disabled = true
    this.say(this.waitingTextValue)

    permission
      .then((state) => {
        if (state !== "granted") {
          throw push.failure(state === "denied" ? this.blockedTextValue : this.notGrantedTextValue)
        }

        return push.subscribeAndRegister(this.settings)
      })
      .then(() => window.location.reload())
      .catch((error) => {
        this.buttonTarget.disabled = false
        this.say(error?.readable ? error.message : this.failedTextValue)
      })
  }

  say(message) {
    this.statusTarget.textContent = message
    this.statusTarget.hidden = false
  }

  // iPadOS reports itself as a Mac; touch points separate it from desktop Safari, which has no Home Screen.
  get isApplePortable() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
           (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)
  }

  get settings() {
    return {
      vapidKey: this.vapidKeyValue,
      registerPath: this.registerPathValue,
      knownEndpoints: this.knownEndpointsValue,
      registerFailedText: this.registerFailedTextValue
    }
  }
}
